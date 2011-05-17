PREFIX=/usr
BINDIR=$(DESTDIR)$(PREFIX)/bin
MANS=sbalance sdeposit
BINS=sbalance sdeposit

all: build

build:
	@test -f bin/shflags || (echo "Run 'git submodule init && git submodule update' first." ; exit 1 )

	for man in $(MANS); do \
		./mdwn2man $$man 1 doc/$$man.mdwn > $$man.1; \
	done

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
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
