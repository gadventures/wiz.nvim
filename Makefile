FILE ?= tests/
NVIM ?= nvim

.PHONY: test lint fmt

test:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory $(FILE) {minimal_init='tests/minimal_init.lua', sequential=true}"

lint:
	stylua --check lua tests plugin && selene lua plugin

fmt:
	stylua lua tests plugin
