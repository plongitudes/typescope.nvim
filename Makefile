# Housekeeping. Building and testing live in scripts/build-oracle.sh and
# tests/run.sh; see CONTRIBUTING.md.

RELEASE_BIN := oracle/target/release/typescope-oracle

.PHONY: clean distclean

# Everything cargo built (oracle/target: several GB, mostly the debug build)
# EXCEPT the release binary, which a local setup may point oracle.path at:
# deleting it would break the editor until the next 2-3 minute build. The
# suites that need the debug binary skip until scripts/build-oracle.sh runs.
clean:
	@du -sh oracle/target 2>/dev/null || true
	@keep=$$(mktemp); \
	if [ -x $(RELEASE_BIN) ]; then cp -p $(RELEASE_BIN) $$keep; fi; \
	cd oracle && cargo clean; cd ..; \
	if [ -s $$keep ]; then mkdir -p $(dir $(RELEASE_BIN)) && mv $$keep $(RELEASE_BIN) && echo "kept $(RELEASE_BIN)"; else rm -f $$keep; fi
	@du -sh oracle/target 2>/dev/null || true

# clean, plus the release binary and the fetched pyrefly source. The next
# scripts/build-oracle.sh fetches pyrefly again (~35 MB) and builds from cold.
distclean:
	cd oracle && cargo clean
	rm -rf oracle/vendor/pyrefly
