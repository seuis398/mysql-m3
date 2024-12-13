package MMM::Agent::Helpers::Actions;

use strict;
use warnings FATAL => 'all';
use English qw( OSNAME );
use MMM::Agent::Helpers::Network;

our $VERSION = '0.01';

if ($OSNAME eq 'linux' || $OSNAME eq 'freebsd') {
	# these libs will always be loaded, use require and then import to avoid that
	use Time::HiRes qw( usleep );
}

=head1 NAME

MMM::Agent::Helpers::Actions - functions for the B<mmm_agentd> helper programs

=cut

use DBI;


=head1 FUNCTIONS

=over 4

=item check_ip($if, $ip)

Check if the IP $ip is configured on interface $if.

=cut

sub check_ip($$) {
	my $if	= shift;
	my $ip	= shift;
	
	if (MMM::Agent::Helpers::Network::check_ip($if, $ip)) {
		_exit_ok('IP address is configured');
	}

	_exit_ok('IP address is not configured', 1);
}


=item configure_ip($if, $ip)

Check if the IP $ip is configured on interface $if. If not, configure it and
send arp requests to notify other hosts.

=cut

sub configure_ip($$) {
	my $if	= shift;
	my $ip	= shift;
	
	if (MMM::Agent::Helpers::Network::check_ip($if, $ip)) {
		_exit_ok('IP address is configured');
	}

	if (!MMM::Agent::Helpers::Network::add_ip($if, $ip)) {
		_exit_error("Could not configure ip adress $ip on interface $if!");
	}
	MMM::Agent::Helpers::Network::send_arp($if, $ip);
	_exit_ok();
}


=item force_arp_refresh($if, $ip)

Send arp requests forcedly to notify other hosts.

=cut

sub force_arp_refresh($$) {
	my $if = shift;
	my $ip = shift;

	MMM::Agent::Helpers::Network::send_arp($if, $ip); 
	_exit_ok();
}


=item clear_ip($if, $ip)

Remove the IP address $ip from interface $if.

=cut

sub clear_ip($$) {
	my $if	= shift;
	my $ip	= shift;
	
	if (!MMM::Agent::Helpers::Network::check_ip($if, $ip)) {
		_exit_ok('IP address is not configured');
	}

	MMM::Agent::Helpers::Network::clear_ip($if, $ip);
	_exit_ok();
}


=item mysql_may_write( )

Check if writes on local MySQL server are allowed.

=cut

sub mysql_may_write() {
	my ($host, $port, $user, $password)	= _get_connection_info();
	_exit_error('No connection info') unless defined($host);

	# connect to server
	my $dbh = _mysql_connect($host, $port, $user, $password);
	_exit_error("Can't connect to MySQL (host = $host:$port, user = $user)! " . $DBI::errstr) unless ($dbh);
	
	# check old read_only state
	(my $read_only) = $dbh->selectrow_array('select @@read_only');
	_exit_error('SQL Query Error: ' . $dbh->errstr) unless (defined $read_only);

	_exit_ok('Not allowed') if ($read_only);
	_exit_ok('Allowed', 1);
}


=item mysql_allow_write( )

Allow writes on local MySQL server. Sets global read_only to 0.

=cut

sub mysql_allow_write() {
	_mysql_set_read_only(0);
	_exit_ok();
}


=item mysql_deny_write( )

Deny writes on local MySQL server. Sets global read_only to 1.

=cut

sub mysql_deny_write() {
	_mysql_set_read_only(1);
	_exit_ok();
}


sub _mysql_set_read_only($) {
	my $read_only_new	= shift;
	my ($host, $port, $user, $password)	= _get_connection_info();
	_exit_error('No connection info') unless defined($host);

	# connect to server
	my $dbh = _mysql_connect($host, $port, $user, $password);
	_exit_error("Can't connect to MySQL (host = $host:$port, user = $user)! " . $DBI::errstr) unless ($dbh);
	
	# check old read_only state
	(my $read_only_old) = $dbh->selectrow_array('select @@read_only');
	_exit_error('SQL Query Error: ' . $dbh->errstr) unless (defined $read_only_old);
	return 1 if ($read_only_old == $read_only_new);

	my $res = $dbh->do("set global read_only=$read_only_new");
	_exit_error('SQL Query Error: ' . $dbh->errstr) unless($res);
	
	$dbh->disconnect();
	$dbh = undef;

	return 1;
}


=item kill_sql 

kill all user threads to prevent further writes

=cut

sub kill_sql() {
	
	my ($host, $port, $user, $password)	= _get_connection_info();
	_exit_error('No connection info') unless defined($host);

	# Connect to server
	my $dbh = _mysql_connect($host, $port, $user, $password);
	_exit_error("Can't connect to MySQL (host = $host:$port, user = $user)! " . $DBI::errstr) unless ($dbh);

	my $my_id = $dbh->{'mysql_thread_id'};

	my $max_retries		= $main::config->{max_kill_retries};
	my $elapsed_retries	= 0;
	my $retry			= 1;

	while ($elapsed_retries <= $max_retries && $retry) {
		$retry = 0;

		# Fetch process list
		my $processlist = $dbh->selectall_hashref('SHOW PROCESSLIST', 'Id');
		
		# Kill processes
		foreach my $id (keys(%{$processlist})) {
			# Skip ourselves
			next if ($id == $my_id);
	
			# Skip non-client threads (i.e. I/O or SQL threads used on replication slaves, ...)
			next if ($processlist->{$id}->{User} eq 'system user');
			next if ($processlist->{$id}->{Command} eq 'Daemon');
	
			# skip threads of replication clients
			next if ($processlist->{$id}->{Command} eq 'Binlog Dump');
			next if ($processlist->{$id}->{Command} eq 'Binlog Dump GTID');

			# Give threads a chance to finish if we're not on our last retry
			if ($elapsed_retries < $max_retries
			 && defined ($processlist->{$id}->{Info})
			 && $processlist->{$id}->{Info} =~ /^\s*(\/\*.*?\*\/)?\s*(INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER|REPAIR|OPTIMIZE|ANALYZE|CHECK)/si
			) {
				$retry = 1;
				next;
			}

			# Kill process
			$dbh->do("KILL $id");
		}

		sleep(1) if ($elapsed_retries < $max_retries && $retry);
		$elapsed_retries++;
	}
}


=item sync_with_master( )

Try to sync up a (soon active) master with his peer (old active master) when the I<active_master_role> is moved. 

=cut

sub sync_with_master() {

	my $this = _get_this();

	my ($this_host, $this_port, $this_user, $this_password) = _get_connection_info($this);
	_exit_error('No local connection info') unless defined($this_host);

	# Connect to local server
	my $this_dbh = _mysql_connect($this_host, $this_port, $this_user, $this_password);
	_exit_error("Can't connect to MySQL (host = $this_host:$this_port, user = $this_user)! " . $DBI::errstr) unless ($this_dbh);

	my $wait_pos = '';
	my $old_wait_pos = '';
	my $chk_wait_pos = '';
	my $slave_status = '';
	my $new_slave_status = '';
	my $last_sql_time = '';
	my $last_sql_error_pos = '';
	my $channel_option = '';
	my $command_show_replica = '';
	my $command_start_replica = '';
	my $command_stop_replica = '';

	my $repl_channel = _get_replication_channel($this);

	# if this node has multiple replication channels, add channel option to command
	$channel_option = " FOR CHANNEL '" . $repl_channel . "'" if (defined($repl_channel) && $repl_channel ne "");

	# replication command
	$this_dbh->selectrow_hashref("SHOW SLAVE STATUS");
	if ($this_dbh->err) {
		$command_show_replica  = "SHOW REPLICA STATUS";
		$command_start_replica = "START REPLICA ";
		$command_stop_replica  = "STOP REPLICA ";
	}
	else {
		$command_show_replica  = "SHOW SLAVE STATUS";
		$command_start_replica = "START SLAVE ";
		$command_stop_replica  = "STOP SLAVE ";
	}

	# Determine wait log and wait pos
	do
	{
		usleep(500 * 1000);

		$slave_status = $this_dbh->selectrow_hashref($command_show_replica . $channel_option);
		_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless defined($slave_status);

		$new_slave_status = _slave_status_key_rename($slave_status);
	} while ($new_slave_status->{Source_Log_File} ne $new_slave_status->{Relay_Source_Log_File}
			or $new_slave_status->{Read_Source_Log_Pos} - $new_slave_status->{Exec_Source_Log_Pos} > 1024 * 1024);

	sleep(2);
	$this_dbh->do($command_stop_replica . 'IO_THREAD' . $channel_option);

	# Sync with the relay log.
	do
	{
		$slave_status = $this_dbh->selectrow_hashref($command_show_replica . $channel_option);
		_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless defined($slave_status);

		$new_slave_status = _slave_status_key_rename($slave_status);
		$wait_pos = join(":", $new_slave_status->{Source_Log_File}, $new_slave_status->{Read_Source_Log_Pos});
		$chk_wait_pos = join(":", $new_slave_status->{Relay_Source_Log_File}, $new_slave_status->{Exec_Source_Log_Pos});

		if ($chk_wait_pos ne $old_wait_pos) {
			$last_sql_time = time()
		}
		elsif (time() - $last_sql_time > 600) {
			# give up
			$chk_wait_pos = $wait_pos;
		}

		if ($new_slave_status->{Replica_SQL_Running} eq 'No') {
			if($chk_wait_pos eq $last_sql_error_pos) {
				$this_dbh->do($command_start_replica . 'IO_THREAD' . $channel_option);
				_exit_error('SQL Thread Error !!');
			}

			# re-try
			$this_dbh->do($command_start_replica . 'SQL_THREAD' . $channel_option);
			$last_sql_error_pos = $chk_wait_pos;
		}

		$old_wait_pos = $chk_wait_pos;
		usleep(200 * 1000);
	} while ($wait_pos ne $chk_wait_pos) ;

	$this_dbh->do($command_start_replica . 'IO_THREAD' . $channel_option);
	$this_dbh->disconnect;

	_exit_ok('');
}


=item set_active_master($new_master)

Try to catch up with the old master as far as possible and change the master to the new host.

=cut

sub set_active_master($) {
	my $new_peer = shift;
	_exit_error('Name of new master is missing') unless (defined($new_peer));

	my $this = _get_this();
	my $command_show_replica = '';
	my $command_start_replica = '';
	my $command_stop_replica = '';

	_exit_error('New master is equal to local host!?') if ($this eq $new_peer);

	# Get local connection info
	my ($this_host, $this_port, $this_user, $this_password) = _get_connection_info($this);
	_exit_error("No connection info for local host '$this_host'") unless defined($this_host);

	# Get connection info for new peer
	my ($new_peer_host, $new_peer_port, $new_peer_user, $new_peer_password) = _get_connection_info($new_peer);
	_exit_error("No connection info for new peer '$new_peer'") unless defined($new_peer_host);


	# Connect to local server
	my $this_dbh = _mysql_connect($this_host, $this_port, $this_user, $this_password);
	_exit_error("Can't connect to MySQL (host = $this_host:$this_port, user = $this_user)! " . $DBI::errstr) unless ($this_dbh);


	# Get replication credentials & channel name
	my ($repl_user, $repl_password) = _get_replication_credentials($new_peer);
	my $repl_channel = _get_replication_channel($this);

	# Change master command
	my $sql = "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$new_peer_host', SOURCE_PORT=$new_peer_port,"
		. " SOURCE_USER='$repl_user', SOURCE_PASSWORD='$repl_password', ";
	my $channel_option = "";
	my $log_msg = "";

	# if this node has multiple replication channels, add channel option to command
	$channel_option = " FOR CHANNEL '" . $repl_channel . "'" if (defined($repl_channel) && $repl_channel ne "");

	# replication command
	$this_dbh->selectrow_hashref("SHOW SLAVE STATUS");
	if ($this_dbh->err) {
		$command_show_replica  = "SHOW REPLICA STATUS";
		$command_start_replica = "START REPLICA ";
		$command_stop_replica  = "STOP REPLICA ";
	}
	else {
		$command_show_replica  = "SHOW SLAVE STATUS";
		$command_start_replica = "START SLAVE ";
		$command_stop_replica  = "STOP SLAVE ";
	}

	# if this host is a slave of the new master, exit !! (nothing to do)
	my $slave_status = $this_dbh->selectrow_hashref($command_show_replica . $channel_option);
	_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless defined($slave_status);

	my $old_peer_ip = exists($slave_status->{Master_Host}) ? $slave_status->{Master_Host} : $slave_status->{Source_Host};
	_exit_error('No ip for old peer') unless ($old_peer_ip);
	my $old_peer = _find_host_by_ip($old_peer_ip);
	_exit_error('Invalid master host in show replica status') unless ($old_peer);

	_exit_ok('We are already a slave of the new master') if ($old_peer eq $new_peer);
	

	# Get gtid_mode of local server
	(my $gtid_mode) = $this_dbh->selectrow_array('SELECT @@global.gtid_mode');

	
	if ( substr($gtid_mode, 0, 2) eq "ON" ) {
		# Change master command (GTID)
		$sql = $sql . "SOURCE_AUTO_POSITION=1";
		$log_msg = "starting replication (gtid auto-position)";
	}
	else {
		# Get new peer's master log position (for change master)
		# Connect to new peer
		my $new_peer_dbh = _mysql_connect($new_peer_host, $new_peer_port, $new_peer_user, $new_peer_password);
		_exit_error("Can't connect to MySQL (host = $new_peer_host:$new_peer_port, user = $new_peer_user)! " . $DBI::errstr) unless ($new_peer_dbh);

		# Get log position of new master
		my $new_master_status = $new_peer_dbh->selectrow_hashref('SHOW MASTER STATUS');
		$new_master_status = $new_peer_dbh->selectrow_hashref('SHOW BINARY LOG STATUS') if ($new_peer_dbh->err);
		_exit_error('SQL Query Error: ' . $new_peer_dbh->errstr) unless($new_master_status);

		my $master_log = $new_master_status->{File};
		my $master_pos = $new_master_status->{Position};

		$new_peer_dbh->disconnect;

		# Change master command (non-GTID)
		$sql = $sql . "SOURCE_LOG_FILE='$master_log', SOURCE_LOG_POS=$master_pos";

		$log_msg = "starting replication in log '" . $master_log . "' at position " . $master_pos;
	}

	# if this node has multiple replication channels, add "channel option" to command
	if ( $repl_channel ne "" ) {
		$sql = $sql . $channel_option;
		$log_msg = $log_msg . ", channel '" . $repl_channel . "'";
	}


	# If Gtid_mode is off, wait sync
	if ( substr($gtid_mode, 0, 2) ne "ON" ) {
		my $wait_pos = '';
		my $old_wait_pos = '';
		my $new_slave_status = '';
			
		# Determine wait log and wait pos
		do
		{
			$old_wait_pos = $wait_pos;

			$slave_status = $this_dbh->selectrow_hashref($command_show_replica . $channel_option);
			_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless defined($slave_status);

			$new_slave_status = _slave_status_key_rename($slave_status);

			$wait_pos = join(":", $new_slave_status->{Source_Log_File}, $new_slave_status->{Read_Source_Log_Pos});
			usleep(500 * 1000);
		} while ($old_wait_pos ne $wait_pos);

		$this_dbh->do($command_stop_replica . 'IO_THREAD' . $channel_option);

		my $chk_wait_pos = '';
		my $sql_thread_status = '';
		my $last_sql_time = '';
		my $last_sql_error_pos = '';
		$old_wait_pos = '';
		
		# Sync with the relay log.
		do
		{
			$slave_status = $this_dbh->selectrow_hashref($command_show_replica . $channel_option);
			_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless defined($slave_status);

			$new_slave_status = _slave_status_key_rename($slave_status);

			$sql_thread_status  = $new_slave_status->{Replica_SQL_Running};
			$wait_pos = join(":", $new_slave_status->{Source_Log_File}, $new_slave_status->{Read_Source_Log_Pos});
			$chk_wait_pos = join(":",  $new_slave_status->{Relay_Source_Log_File}, $new_slave_status->{Exec_Source_Log_Pos});

			if ($chk_wait_pos ne $old_wait_pos) {
				$last_sql_time = time()
			}
			elsif (time() - $last_sql_time > 600) {
				# give up replication sync
				$chk_wait_pos = $wait_pos;
			}

			if ($new_slave_status->{Replica_SQL_Running} eq 'No') {
				if($chk_wait_pos eq $last_sql_error_pos) {
					$this_dbh->do($command_start_replica . 'IO_THREAD' . $channel_option);
					_exit_error('SQL Thread Error !!');
				}

				# re-try
				$this_dbh->do($command_start_replica . 'SQL_THREAD' . $channel_option);
				$last_sql_error_pos = $chk_wait_pos;
			}

			$old_wait_pos = $chk_wait_pos;
			usleep(200 * 1000);
		} while ( $wait_pos ne $chk_wait_pos );
	}

	# Stop slave
	my $res = $this_dbh->do($command_stop_replica . $channel_option);
	_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless($res);

	# Change master
	if ($command_show_replica eq 'SHOW SLAVE STATUS') {
		my %replacements = (
			'CHANGE REPLICATION SOURCE' => 'CHANGE MASTER',
			'SOURCE_HOST' => 'MASTER_HOST',
			'SOURCE_PORT' => 'MASTER_PORT',
			'SOURCE_USER' => 'MASTER_USER',
			'SOURCE_PASSWORD' => 'MASTER_PASSWORD',
			'SOURCE_LOG_FILE' => 'MASTER_LOG_FILE',
			'SOURCE_LOG_POS' => 'MASTER_LOG_POS',
			'SOURCE_AUTO_POSITION' => 'MASTER_AUTO_POSITION'
		);
		my $pattern = join('|', map { quotemeta } keys %replacements);
		$sql =~ s/($pattern)/$replacements{$1}/g;
	}
	$res = $this_dbh->do($sql);
	_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless($res);

	# Start slave
	$res = $this_dbh->do($command_start_replica . $channel_option);
	_exit_error('SQL Query Error: ' . $this_dbh->errstr) unless($res);

	$this_dbh->disconnect;

	_exit_ok($log_msg);
}


=item _get_connection_info([$host])

Get connection info for host $host || local host.

=cut

sub _get_connection_info($) {
	my $host = shift;

	_exit_error('No config present') unless (defined($main::config));

	$host = $main::config->{this} unless defined($host);
	_exit_error('No config present') unless (defined($main::config->{host}->{$host}));

	return (
		$main::config->{host}->{$host}->{ip},
		$main::config->{host}->{$host}->{mysql_port},
		$main::config->{host}->{$host}->{agent_user},
		$main::config->{host}->{$host}->{agent_password}
	);
}

sub _get_this() {
	_exit_error('No config present') unless (defined($main::config));
	return $main::config->{this};
}

sub _mysql_connect($$$$) {
	my ($host, $port, $user, $password)	= @_;
	my $dsn = "DBI:mysql:host=$host;port=$port;mysql_connect_timeout=3";
	return DBI->connect($dsn, $user, $password, { PrintError => 0, mysql_get_server_pubkey => 1 });
}

sub _find_host_by_ip($) {
	my $ip = shift;
	return undef unless ($ip);

	_exit_error('No config present') unless (defined($main::config));

	my $hosts = $main::config->{host};
	foreach my $host (keys(%$hosts)) {
		return $host if ($hosts->{$host}->{ip} eq $ip);
	}
	
	return undef;
}

sub _get_replication_credentials($) {
	my $host = shift;
	return undef unless ($host);

	_exit_error('No config present') unless (defined($main::config));
	_exit_error('No config present') unless (defined($main::config->{host}->{$host}));

	return (
		$main::config->{host}->{$host}->{replication_user},
		$main::config->{host}->{$host}->{replication_password},
	);
}

sub _get_replication_channel($) {
	my $host = shift;
	return undef unless ($host);

	_exit_error('No config present') unless (defined($main::config));
	_exit_error('No config present') unless (defined($main::config->{host}->{$host}));

	return $main::config->{host}->{$host}->{replication_channel};
}

sub _exit_error {
	my $msg	= shift;

	print "ERROR: $msg\n"	if ($msg);
	print "ERROR\n"			unless ($msg);

	exit(255);
}

sub _exit_ok {
	my $msg	= shift;
	my $ret = shift || 0;

	print "OK: $msg\n"	if ($msg);
	print "OK\n"		unless ($msg);

	exit($ret);
}

sub _verbose_exit($$) {
	my $ret	= shift;
	my $msg	= shift;

	print $msg, "\n";
	exit($ret);
}

sub _slave_status_key_rename {
	my ($row) = @_;
	my %key_map = (
		'Master_Host' => 'Source_Host',
		'Master_Log_File' => 'Source_Log_File',
		'Relay_Master_Log_File' => 'Relay_Source_Log_File',
		'Read_Master_Log_Pos' => 'Read_Source_Log_Pos',
		'Exec_Master_Log_Pos' => 'Exec_Source_Log_Pos',
		'Slave_IO_Running' => 'Replica_IO_Running',
		'Slave_SQL_Running' => 'Replica_SQL_Running',
		'Seconds_Behind_Master' => 'Seconds_Behind_Source'
	);

	my %new_row;
	while (my ($old_key, $value) = each %$row) {
		my $new_key = $key_map{$old_key} // $old_key;
		$new_row{$new_key} = $value;
	}

	return \%new_row;
}

1;
