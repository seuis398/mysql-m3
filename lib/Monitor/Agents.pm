package MMM::Monitor::Agents;
use base 'Class::Singleton';

use strict;
use warnings FATAL => 'all';
use Log::Log4perl qw(:easy);
use IO::Handle;
use File::Temp;
use File::Basename;
use MMM::Monitor::Agent;
use MMM::Monitor::Role;
use Net::Ping;
use DBI;




=head1 NAME

MMM::Monitor::Agents - single instance class holding status information for all agent hosts

=head1 SYNOPSIS

	# Get the instance
	my $agents = MMM::Monitor::Agents->instance();

=cut

sub _new_instance($) {
	my $class = shift;
	my $data = {};

	my @hosts		= keys(%{$main::config->{host}});

	foreach my $host (@hosts) {
		$data->{$host} = new MMM::Monitor::Agent:: (
			host		=> $host,
			mode		=> $main::config->{host}->{$host}->{mode},
			ip		=> $main::config->{host}->{$host}->{ip},
			port		=> $main::config->{host}->{$host}->{agent_port},
			mysql_port	=> $main::config->{host}->{$host}->{mysql_port},
			monitor_user	=> $main::config->{host}->{$host}->{monitor_user},
			monitor_password=> $main::config->{host}->{$host}->{monitor_password},
			repl_channel	=> $main::config->{host}->{$host}->{replication_channel},
			state		=> 'UNKNOWN',
			roles		=> [],
			uptime		=> 0,
			last_uptime => 0
		);
	}
	return bless $data, $class;
}


=head1 FUNCTIONS

=over 4

=item exists($host)

Check if host $host exists.

=cut

sub exists($$) {
	my $self	= shift;
	my $host	= shift;
	return defined($self->{$host});
}


=item get($host)

Get agent for host $host.

=cut

sub get($$) {
	my $self	= shift;
	my $host	= shift;
	return $self->{$host};
}


=item state($host)

Get state of host $host.

=cut

sub state($$) {
	my $self	= shift;
	my $host	= shift;
	LOGDIE "Can't get state of invalid host '$host'" if (!defined($self->{$host}));
	return $self->{$host}->state;
}


=item online_since($host)

Get time since host $host is online.

=cut

sub online_since($$) {
	my $self	= shift;
	my $host	= shift;
	LOGDIE "Can't get time since invalid host '$host' is online" if (!defined($self->{$host}));
	return $self->{$host}->online_since;
}


=item set_state($host, $state)

Set state of host $host to $state.

=cut

sub set_state($$$) {
	my $self	= shift;
	my $host	= shift;
	my $state	= shift;

	LOGDIE "Can't set state of invalid host '$host'" if (!defined($self->{$host}));
	$self->{$host}->state($state);
}


=item get_status_info

Get string containing status information.

=cut

sub get_status_info($) {
	my $self	= shift;
	my $detailed= shift || 0;
	my $res		= '';
	my $agent_res = '';
	my $p = Net::Ping->new("icmp");

	$res .= "== MySQL & Virtual IP status ==\n";

	keys (%$self); # reset iterator
	foreach my $host (sort(keys(%$self))) {
		my $agent = $self->{$host};
		next unless $agent;
		$agent_res	.= "# Warning: agent on host $host is not reachable\n" if ($agent->agent_down());

		my @arr_role;
		foreach my $check_roles (@{$agent->roles}) {
			$check_roles =~ /(writer|reader)\((.*)\)/;
			my $vip = $2;
			my $ping_check = "Error";
			$ping_check = "OK" if $p->ping($vip, 1);

			unshift @arr_role, sprintf("%s/Ping_%s", $check_roles, $ping_check);
		}

                $res .= sprintf("  %s(%s) %s/%s. Roles: %s\n", $host, join(':', $agent->ip, $agent->mysql_port), $agent->mode, $agent->state, join(', ', sort(@arr_role)));
	}
	
	$p->close();

	$res = $agent_res . $res if ($detailed);
	return $res;
}


=item get_replication_status

Get Replication Status (realtime db query)
Get MMM Vip Ping Status (use Net::Ping)

=cut

sub get_replication_status($) {
	my $res  = '';
	my $channel_option = '';
	my $channel_info = '';
	my $self = shift;

	$res = sprintf("\n== Replication Status ==\n"); 

	keys (%$self); # reset iterator
	foreach my $host (sort(keys(%$self))) {
		my $agent = $self->{$host};
		next unless $agent;

		my $check_dbh = _mysql_connect($agent->ip, $agent->mysql_port, $agent->monitor_user, $agent->monitor_password);
		next unless($check_dbh);

		if (defined($agent->repl_channel) && $agent->repl_channel ne '') {
			$channel_option = " FOR CHANNEL '" . $agent->repl_channel . "'";
			$channel_info = " | Channel_Name: " . $agent->repl_channel;
		}

		my $slave_status = $check_dbh->selectrow_hashref("SHOW SLAVE STATUS" . $channel_option);
		if (defined($slave_status)) {
			my $ss_master = $slave_status->{Master_Host};
			my $ss_repl_thread = join('/', $slave_status->{Slave_IO_Running}, $slave_status->{Slave_SQL_Running});

			my $ss_sbm = '-';
			$ss_sbm = $slave_status->{Seconds_Behind_Master}  if ($slave_status->{Slave_IO_Running} eq "Yes" && $slave_status->{Slave_SQL_Running} eq "Yes");

			my $read_only_status = $check_dbh->selectrow_hashref("SHOW GLOBAL VARIABLES LIKE 'read_only'"); 

			$res .= sprintf("  %s [Master: %s | Replication_Thread: %s | Seconds_Behind_Master: %s | Read_Only: %-3s%s]\n"
					,$agent->host, $ss_master, $ss_repl_thread, $ss_sbm, $read_only_status->{Value}, $channel_info);
		}
		$check_dbh->disconnect;
	}
	return $res;
}


=item get_version_info 

Get DB & Agent Version Information

=cut

sub get_version_info($) {
	my $res  = '';
	my $self = shift;

	$res = sprintf("\n== Version Info ==\n");

	keys (%$self); # reset iterator
	foreach my $host (sort(keys(%$self))) {
		my $agent = $self->{$host};
		next unless $agent;

		my $check_dbh = _mysql_connect($agent->ip, $agent->mysql_port, $agent->monitor_user, $agent->monitor_password);
		next unless($check_dbh);

		my $version_status = $check_dbh->selectrow_hashref("select version() as dbversion");
		if (defined($version_status)) {
			my $db_ver = $version_status->{dbversion};
			my $mmm_ver = $agent->cmd_get_agent_version(1);
			$mmm_ver = "Unknown" if ($mmm_ver =~ /^ERROR/);
			$mmm_ver = "not connected" if ($mmm_ver eq '0');

			$res .= sprintf("  %s [MySQL %s] - Agent: %s\n", $agent->host, $db_ver, $mmm_ver);
		}
		$check_dbh->disconnect;
	}
	return $res;
}


=item save_status

Save status information into status file.

=cut

sub save_status($) {
	my $self	= shift;
	
	my $filename = $main::config->{monitor}->{status_path};

	my ($fh, $tempname) = File::Temp::tempfile(basename($filename) . ('X' x 10), UNLINK => 0, DIR => dirname($filename));

	keys (%$self); # reset iterator
	while (my ($host, $agent) = each(%$self)) {
		next unless $agent;
		printf($fh "%s|%s|%s\n", $host, $agent->state, join(',', sort(@{$agent->roles})));
	}
	IO::Handle::flush($fh);
	IO::Handle::sync($fh);
	close($fh);
	rename($tempname, $filename) || LOGDIE "Can't savely overwrite status file '$filename'!";
	return;
}


=item load_status

Load status information from status file

=cut

sub load_status($) {
	my $self	= shift;

	my $filename = $main::config->{monitor}->{status_path};
	
	# Open status file
	unless (open(STATUS, '<', $filename)) {
		FATAL "Couldn't open status file '$filename': Starting up without status information.";
		return;
	}

	while (my $line = <STATUS>) {
		chomp($line);
		my ($host, $state, $roles) = split(/\|/, $line);
		unless (defined($self->{$host})) {
			WARN "Ignoring saved status information for unknown host '$host'";
			next;
		}

		# Parse roles
		my @saved_roles_str = sort(split(/\,/, $roles));
		my @saved_roles = ();
		foreach my $role_str (@saved_roles_str) {
			my $role = MMM::Monitor::Role->from_string($role_str);
			push (@saved_roles, $role) if defined($role);
		}

		$self->{$host}->state($state);
		$self->{$host}->roles(\@saved_roles);
	}
	close(STATUS);
	return;
}


sub _mysql_connect($$$$) {
	my ($host, $port, $user, $password) = @_;
	my $dsn = "DBI:mysql:host=$host;port=$port;mysql_connect_timeout=3";
	return DBI->connect($dsn, $user, $password, { PrintError => 0 });
}

1;
