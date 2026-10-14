.PHONY: build run test

build:
	bash scripts/build.sh

run: build
	open build/Screenboop.app

test:
	swift test
