include VERSION

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

PERL_VER := $(shell sh PERL_VERSION)
HW_PLATFORM := $(shell uname -i)
PERL_LIBS = lib/perl_libs_$(PERL_VER)_$(HW_PLATFORM).tar.gz

install_common:
	mkdir -p $(MODULEDIR)/MMM $(BINDIR) $(LOGDIR) $(CONFDIR) $(ETCDIR)/init.d $(TMPDIR)

	cp -r lib/*  $(MODULEDIR)/MMM/
	cp -r bin/*  $(BINDIR)/
	cp -r sbin/* $(BINDIR)/
	cp -r etc/init.d/*  $(ETCDIR)/init.d/
	chmod -R u+x $(BINDIR)
	chmod u+x $(ETCDIR)/init.d/*

	find $(ETCDIR)/init.d/ $(MODULEDIR)/MMM/ -type f -exec sed -i 's#%PREFIX%#$(PREFIX)#g' {} \;
	find $(BINDIR)/ -type f -exec sed -i '/^#!\/usr\/bin\/env perl$$/ a BEGIN { unshift @INC,"$(MODULEDIR)"; }' {} \;
	find $(BINDIR)/mmm_* -exec vi -c "%s/2.2.1/$(VERSION) (mysql-m3)/g" -c "wq" "{}" \;	

	if [ -f $(PERL_LIBS) ]; \
	then tar xfz $(PERL_LIBS) --directory=$(MODULEDIR); \
	fi
	echo $(MODULEDIR) > /etc/ld.so.conf.d/mysql-mmm.conf
	/sbin/ldconfig

install_agent: install_common
	ln -sf $(ETCDIR)/init.d/mysql-mmm-agent $(INITDIR)/mysql-mmm-agent
	cp -r etc/mysql-mmm/mmm_agent.conf $(CONFDIR)/mmm_agent_example.conf
	chmod 600 $(CONFDIR)/mmm_agent_example.conf
	find $(CONFDIR)/ -type f -name "*mmm*" -exec sed -i 's#%PREFIX%#$(PREFIX)#g' {} \;
	find $(MODULEDIR)/MMM/Agent/Agent.pm -exec vi -c "%s/2.2.1/$(VERSION) (mysql-m3)/g" -c "wq" "{}" \;

install_monitor: install_common
	ln -sf $(ETCDIR)/init.d/mysql-mmm-monitor $(INITDIR)/mysql-mmm-monitor
	cp -r etc/mysql-mmm/mmm_mon.conf $(CONFDIR)/mmm_mon_example.conf
	chmod 600 $(CONFDIR)/mmm_mon_example.conf
	find $(CONFDIR)/ -type f -name "*mmm*" -exec sed -i 's#%PREFIX%#$(PREFIX)#g' {} \;

install: install_agent install_monitor
