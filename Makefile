default:
	@test -f bin/shflags || (echo "Run 'git submodule init && git submodule update' first." ; exit 1 )
