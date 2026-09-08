all:
	@echo "Try: make test"
	@false

runtests:
	bash ./test-gpu-bank.sh
	bash ./test.sh

test:
	../wvtestrun $(MAKE) runtests

functional-gpu:
	bash ./test-gpu-bank.sh

clean::
	rm -f *~
