#!/usr/bin/python3

# helper to generate a ninja dyndep and include file

import subprocess
import pathlib
import textwrap

def git_version():
	return subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode('ascii').strip()

def generate_include(args):
	# generates our include file
	with args.output_file.open('wt') as f:
		values = {
			'git_hash': git_version(),
			'git_short_hash': git_version()[:7]
		}
		f.write(textwrap.dedent("""
			#if defined __ninjabuild_auto_version_included
				#endinput
			#endif
			#define __ninjabuild_auto_version_included
			
			#define GIT_COMMIT_HASH "{git_hash}"
			#define GIT_COMMIT_SHORT_HASH "{git_short_hash}"
		""".format(**values))[1:])

def generate_dyndep(args):
	# regenerated whenever .git/HEAD changes
	# change the implicit dependency we rely on based on what ref HEAD points to
	with open('.git/HEAD', 'rt') as git_head:
		_, head_path = git_head.read().split()
	
	# we determine the file name by stripping .dd from `file.ext.dd`
	include_path = args.output_file.with_suffix('')
	
	# TODO include our plugin file as a dynamic dependency here
	with args.output_file.open('wt') as out:
		out.write('ninja_dyndep_version = 1\n')
		out.write(f'build {include_path}: dyndep | .git/{head_path}\n')

if __name__ == '__main__':
	import argparse
	
	parser = argparse.ArgumentParser(
			description = "Automatic version integration script for ninja.",
			usage = "%(prog)s [options]")
	subparsers = parser.add_subparsers(help = 'sub-command help')
	
	version_cmd = subparsers.add_parser('include', help = "Generate include file")
	version_cmd.add_argument('output_file', help = "Output file", type = pathlib.Path)
	version_cmd.set_defaults(call = generate_include)
	
	dyndep_cmd = subparsers.add_parser('dyndep', help = "Generate dyndep file")
	dyndep_cmd.add_argument('output_file', help = "Output file", type = pathlib.Path)
	dyndep_cmd.set_defaults(call = generate_dyndep)
	
	args = parser.parse_args()
	
	if 'call' in args:
		args.call(args)
	else:
		parser.print_help()
