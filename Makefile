ifndef PREFIX
	PREFIX = /usr/local/mysql-mmm
endif

MODULEDIR = $(PREFIX)/lib
BINDIR    = $(PREFIX)/bin
LOGDIR    = $(PREFIX)/log
CONFDIR   = $(PREFIX)/conf
ETCDIR    = $(PREFIX)/etc
TMPDIR    = $(PREFIX)/tmp
INITDIR   = /etc/init.d

install_common:
	mkdir -p $(MODULEDIR)/MMM $(BINDIR) $(LOGDIR) $(CONFDIR) $(ETCDIR)/init.d $(TMPDIR)

	cp -r lib/*  $(MODULEDIR)/MMM/
	cp -r bin/*  $(BINDIR)/
	cp -r sbin/* $(BINDIR)/
	cp -r etc/init.d/*  $(ETCDIR)/init.d/
	chmod -R u+x $(BINDIR)

	find $(ETCDIR)/init.d/ $(MODULEDIR)/MMM/ -type f -exec sed -i 's#%PREFIX%#$(PREFIX)#g' {} \;
	find $(BINDIR)/ -type f -exec sed -i '/^#!\/usr\/bin\/env perl$$/ a BEGIN { unshift @INC,"$(MODULEDIR)"; }' {} \;

install_agent: install_common
	ln -sf $(ETCDIR)/init.d/mysql-mmm-agent $(INITDIR)/mysql-mmm-agent
	cp -r etc/mysql-mmm/mmm_agent.conf $(CONFDIR)/mmm_agent_example.conf
	chmod 600 $(CONFDIR)/mmm_agent_example.conf
	find $(CONFDIR)/ -type f -name "*mmm*" -exec sed -i 's#%PREFIX%#$(PREFIX)#g' {} \;

install_monitor: install_common
	ln -sf $(ETCDIR)/init.d/mysql-mmm-monitor $(INITDIR)/mysql-mmm-monitor
	cp -r etc/mysql-mmm/mmm_mon.conf $(CONFDIR)/mmm_mon_example.conf
	chmod 600 $(CONFDIR)/mmm_mon_example.conf
	find $(CONFDIR)/ -type f -name "*mmm*" -exec sed -i 's#%PREFIX%#$(PREFIX)#g' {} \;

install: install_agent install_monitor
