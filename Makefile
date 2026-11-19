.PHONY: help install build app demo screenshots test clean

help:
	@echo "make install       check tools, set up .venv, build, sign and install PhotoHub (scripts/install.sh)"
	@echo "make build         release build of PhotoHub and PhotoHubAnalyzer, nothing installed"
	@echo "make app           assemble, sign and install PhotoHub.app (scripts/build_app.sh)"
	@echo "make demo          demo library from free stock photos and a separate demo app (scripts/demo.sh)"
	@echo "make screenshots   regenerate docs/images from the demo (scripts/screenshots.sh)"
	@echo "make test          backend, Swift build and the removal self-test (scripts/check.sh)"
	@echo "make clean         remove Swift build folders and build/"

install:
	scripts/install.sh

build:
	swift build -c release --package-path App

app:
	scripts/build_app.sh

demo:
	scripts/demo.sh

screenshots:
	scripts/screenshots.sh

test:
	scripts/check.sh

clean:
	rm -rf App/.build build
