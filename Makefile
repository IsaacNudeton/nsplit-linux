# nsplit: build and install. `make install` only copies files; it enrolls no account and changes no login or network policy (that is `nsplit add`).
PREFIX ?= /usr
DESTDIR ?=
LIBDIR = $(PREFIX)/lib/nsplit
VERSION = $(shell sed -n 's/^NSPLIT_VERSION=//p' lib/nsplit/common.sh)
# pacman versions cannot contain a hyphen: 0.2.0-alpha.3 is packaged as 0.2.0alpha.3 (which sorts after 0.1.0 and before 0.2.0)
PKGVER = $(subst -,,$(VERSION))
HELPERS = nsplit-netns nsplit-fw nsplit-ufw nsplit-pam-gate nsplit-run nsplit-scoped nsplit-sockdir nsplit-mounts

.PHONY: all check install dist
all: check

check:
	@for f in bin/nsplit lib/nsplit/*.sh $(addprefix lib/nsplit/,$(HELPERS)) lib/NetworkManager/dispatcher.d/90-nsplit-uplink; do bash -n $$f || exit 1; done
	@sh -n lib/nsplit/nsplit-pam-gate
	@echo "syntax ok"

install:
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(LIBDIR) $(DESTDIR)$(PREFIX)/share/nsplit $(DESTDIR)$(PREFIX)/lib/systemd/system $(DESTDIR)$(PREFIX)/lib/NetworkManager/dispatcher.d
	install -m 755 bin/nsplit $(DESTDIR)$(PREFIX)/bin/nsplit
	install -m 755 $(addprefix lib/nsplit/,$(HELPERS)) $(DESTDIR)$(LIBDIR)/
	install -m 644 lib/nsplit/*.sh $(DESTDIR)$(LIBDIR)/
	install -m 644 share/nsplit/* $(DESTDIR)$(PREFIX)/share/nsplit/
	for u in lib/systemd/system/*.service lib/systemd/system/*.path lib/systemd/system/*.timer; do sed 's|@LIBDIR@|$(LIBDIR)|g' $$u > $(DESTDIR)$(PREFIX)/lib/systemd/system/$$(basename $$u); chmod 644 $(DESTDIR)$(PREFIX)/lib/systemd/system/$$(basename $$u); done
	install -m 755 lib/NetworkManager/dispatcher.d/90-nsplit-uplink $(DESTDIR)$(PREFIX)/lib/NetworkManager/dispatcher.d/90-nsplit-uplink

dist: check
	tar --transform 's|^|nsplit-$(PKGVER)/|' --exclude-vcs --exclude='*.tar.*' --exclude='*.pkg.*' --exclude=packaging/arch/src --exclude=packaging/arch/pkg -czf nsplit-$(PKGVER).tar.gz bin lib share LICENSE Makefile packaging/arch/PKGBUILD
	@ls -l nsplit-$(PKGVER).tar.gz
