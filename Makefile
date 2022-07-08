.DEFAULT_GOAL := help
.PHONY: help virtualenv kind image deploy

help:
	./demo.sh help

rosa.create:
	./demo.sh rosa-create

rosa.delete:
	./demo.sh rosa-delete

install:
	./demo.sh install

uninstall:
	./demo.sh uninstall

start:
	./demo.sh start
