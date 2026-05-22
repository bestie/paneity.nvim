.PHONY: test

test: deps/plenary.nvim
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests {minimal_init = 'tests/minimal_init.lua'}"

deps/plenary.nvim:
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim deps/plenary.nvim
