.PHONY: build run test

build:
	bash scripts/build.sh

run: build
	open build/screenboop.app

test:
	swift test
