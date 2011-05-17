PREFIX=/usr
BINDIR=$(DESTDIR)$(PREFIX)/bin
MANS=sbalance sdeposit sbank
BINS=sbalance sdeposit sbank sbank-project sbank-user

all: build

build: docs
	@test -f bin/shflags || (echo "Run 'git submodule init && git submodule update' first." ; exit 1 )

	for man in $(MANS); do \
		./mdwn2man $$man 1 doc/$$man.mdwn > $$man.1; \
	done

# If ikiwiki is available, build static html docs suitable for being
# shipped in the software package.
ifeq ($(shell which ikiwiki),)
IKIWIKI=@echo "** ikiwiki not found, skipping building docs" >&2; true
else
IKIWIKI=ikiwiki
endif

docs:
	$(IKIWIKI) doc html -v --wikiname slurm-bank --plugin=goodstuff \
		--no-usedirs --disable-plugin=openid --plugin=sidebar \
		--underlaydir=/dev/null --disable-plugin=shortcut \
		--disable-plugin=smiley \
		--plugin=comments --set comments_pagespec="*" \
		--exclude='news/.*'

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install bin/shflags $(DESTDIR)$(PREFIX)/bin
	for bin in $(BINS); do \
		install bin/$$bin $(DESTDIR)$(PREFIX)/bin; \
	done

	install -d $(DESTDIR)$(PREFIX)/share/man/man1
	for man in $(MANS); do \
		install -m 0644 $$man.1 $(DESTDIR)$(PREFIX)/share/man/man1; \
	done

clean:
	for man in $(MANS); do \
                rm -f $$man.1; \
        done
	rm -rf html doc/.ikiwiki

.PHONY: docs
