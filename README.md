HaskellNet
==========

This package provides client support for the E-mail protocols POP3,
SMTP, and IMAP.

Some examples of how to use the library are contained in the example/
directory.  You should be able to run them by adjusting the file for
your mail server settings and then loading the file in ghci and type
'main'. eg.

  ghci -hide-package monads-fd example/smtpMimeMail.hs
  main
  
If you encounter problems and want to debug the ghci 
debugger works well:

  :set -fbreak-on-exception
  :trace main

## Note on Fork

I made changes to make cabal install on this work on ghc 7.4.1 and
later. 

* removed dependency on haskell-98
* changed import List and Char to import Data.List, Data.Char
* fix a missing Show a type class constraint

