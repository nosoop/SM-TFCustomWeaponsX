#!/usr/bin/python3

import subprocess
import io
import shutil
import platform

def locate_compiler(path = None):
	"""
	Locates the 32- or 64-bit SourcePawn compiler in the directory specified, or PATH if not
	specified.
	"""
	print("""Checking for SourcePawn compiler...""")
	spcomp = shutil.which('spcomp', path = path)
	if 'x86_64' in platform.machine():
		# Use 64-bit spcomp if architecture supports it
		spcomp = shutil.which('spcomp64', path = path) or spcomp
	if not spcomp:
		raise FileNotFoundError('Could not find SourcePawn compiler.')
	return spcomp

def extract_version(spcomp):
	"""
	Extract version string from caption in SourcePawn compiler into a tuple.
	The string is hardcoded in `setcaption(void)` in `sourcepawn/compiler/parser.cpp`
	"""
	p = subprocess.Popen([spcomp], stdout=subprocess.PIPE)
	caption = io.TextIOWrapper(p.stdout, encoding="utf-8").readline()
	
	# extracts last element from output in format "SourcePawn Compiler major.minor.rev.patch"
	*_, version = caption.split()
	return tuple(map(int, version.split('.')))
