PACKAGE := pve-fcsan
VERSION := $(shell dpkg-parsechangelog -S Version 2>/dev/null || echo 1.0.0)

DESTDIR ?=
PERLDIR := $(DESTDIR)/usr/share/perl5
SBINDIR := $(DESTDIR)/usr/sbin
LIBDIR := $(DESTDIR)/usr/share/$(PACKAGE)
WWWDIR := $(DESTDIR)/usr/share/pve-manager/js
UNITDIR := $(DESTDIR)/lib/systemd/system
TEMPLATEDIR := $(DESTDIR)/usr/share/pve-manager/templates/default
BASHCOMPDIR := $(DESTDIR)/usr/share/bash-completion/completions

SAN_MODULES := $(wildcard src/PVE/SAN/*.pm)
ARRAY_MODULES := $(wildcard src/PVE/SAN/Array/*.pm)
FABRIC_MODULES := $(wildcard src/PVE/SAN/Fabric/*.pm)

.PHONY: all install test check deb clean

all:

install:
	install -d $(PERLDIR)/PVE/SAN/Array $(PERLDIR)/PVE/SAN/Fabric $(PERLDIR)/PVE/API2 $(PERLDIR)/PVE/CLI $(PERLDIR)/PVE/Storage/Custom
	install -m 0644 $(SAN_MODULES) $(PERLDIR)/PVE/SAN/
	install -m 0644 $(ARRAY_MODULES) $(PERLDIR)/PVE/SAN/Array/
	install -m 0644 $(FABRIC_MODULES) $(PERLDIR)/PVE/SAN/Fabric/
	install -m 0644 src/PVE/API2/SAN.pm $(PERLDIR)/PVE/API2/
	install -m 0644 src/PVE/CLI/pvesan.pm $(PERLDIR)/PVE/CLI/
	install -m 0644 src/PVE/Storage/Custom/FCSANPlugin.pm src/PVE/Storage/Custom/FCSANVolPlugin.pm $(PERLDIR)/PVE/Storage/Custom/
	install -D -m 0755 bin/pvesan $(SBINDIR)/pvesan
	install -D -m 0755 bin/pvesan-integrate $(LIBDIR)/pvesan-integrate
	install -D -m 0644 www/pvesan.js $(WWWDIR)/pvesan.js
	install -D -m 0644 systemd/pvesan-sync.service $(UNITDIR)/pvesan-sync.service
	install -m 0644 systemd/pvesan-snapshot.service systemd/pvesan-snapshot.timer $(UNITDIR)/
	install -m 0644 systemd/pvesan-reclaim.service systemd/pvesan-reclaim.timer $(UNITDIR)/
	install -D -m 0644 completion/pvesan $(BASHCOMPDIR)/pvesan
	install -m 0644 systemd/pvesan-monitor.service systemd/pvesan-monitor.timer $(UNITDIR)/
	install -m 0644 systemd/pvesan-dr.service systemd/pvesan-dr.timer $(UNITDIR)/
	install -d $(TEMPLATEDIR)
	install -m 0644 templates/pvesan-alert-subject.txt.hbs templates/pvesan-alert-body.txt.hbs $(TEMPLATEDIR)/

# unit tests + compile check; runs anywhere with Perl (PVE modules are stubbed when absent)
test:
	prove -I src -I t/lib t/

check: test
	@command -v node >/dev/null && node --check www/pvesan.js && echo "www/pvesan.js: syntax OK" || true

# exec bits get lost when the tree is copied from Windows or a zip
deb:
	chmod 0755 debian/rules bin/pvesan bin/pvesan-integrate
	dpkg-buildpackage -b -us -uc

clean:
	rm -rf debian/$(PACKAGE) debian/.debhelper debian/files debian/*.substvars debian/*.debhelper* debian/debhelper-build-stamp
