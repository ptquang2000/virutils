vim.g.project_define = {
	lldb_command = "pkexec",
	lldb_args = "/usr/bin/lldb-dap",
	cpp_program = vim.fn.getcwd() .. "/build/virutil",
}

vim.keymap.set("n", "<leader>b", function()
	vim.cmd("rightbelow vsplit | terminal sh build.sh")
	vim.cmd("startinsert")
end, { desc = "virutils: [B]uild in split" })
