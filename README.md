![Icon](https://github.com/matthewyang204/OpenUnarchiver/blob/3b5dcc8e886d14024a56da66b17ef401950b32b1/icons/unarchiver.png)

# The OpenUnarchiver is an Objective-C application for uncompressing archive files.

* Supports more formats than I can remember. Zip, Tar, Gzip, Bzip2, 7-Zip, Rar, LhA, StuffIt, several old Amiga file and disk archives, CAB, LZX, stuff I don't even know what it is. Read [http://code.google.com/p/theunarchiver/wiki/SupportedFormats the wiki page] for a more thorough listing of formats.
* Copies the Finder file-copying/moving/deleting interface for its interface.
* Uses character set autodetection code from Mozilla to auto-detect the encoding of the filenames in the archives.
* Supports split archives for certain formats, like RAR.
* Version 2.0 uses an archive-handling library built largely from scratch in Objective-C, which makes adding support for new formats and algorithms very easy.
* Uses libxad (http://sourceforge.net/projects/libxad/) for older and more obscure formats. This is an old Amiga library for handling unpacking of archives.
* The unarchiving engine itself is multi-platform, and command-line tools exist for Linux, Windows and other OSes.
