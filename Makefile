# rayffi — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt compare stall clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./rayffi (links against the system zlib)
	rm -f rayffi
	ray build --native --release -o rayffi src/main.ray

test: ## Tests on the VM
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

compare: build ## zlib against std/deflate and std/inflate on 8 MiB of generated text
	./rayffi compare

stall: build ## A ticker fiber's longest gap, plain extern against extern blocking, on 1, 2 and all workers
	RAYLANG_THREADS=1 ./rayffi stall -f 4
	RAYLANG_THREADS=2 ./rayffi stall
	./rayffi stall

clean: ## Remove the binary
	rm -f rayffi
