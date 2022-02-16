
## Installation

If you have Cabal-Install installed, the following two commands should install the latest SCC package on your system:

    cabal update
    cabal install scc

If everything goes well, there should be executable named `shsh`. On Unix it gets installed in your `$HOME/.cabal/bin/` directory by default.

## Command-line Shell

To see the options supported by _shsh_, type `shsh --help` and you'll get:

    Usage: shsh (-c <command> | -f <file> | -i | -s) 
      -c       --command      Execute a single command
      -h       --help         Show help
      -f file  --file=file    Execute commands from a script file
      -i       --interactive  Execute commands interactively
      -s       --stdin        Execute commands from the standard input

Here are a few simple command examples:

     Bash + GNU tools          shsh
     ----------------          ----
     echo "Hello, World!"      echo "Hello, World!\n"
     wc -c                     count | show | concatenate
     wc -l                     foreach line then substitute x else suppress end | count | show | concatenate
     grep "foo"                foreach line having substring "foo" then append "\n" else suppress end
     sed "s:foo:bar:"          foreach substring "foo" then substitute "bar" end
     sed "s:foo:[\\&]:"        foreach substring "foo" then prepend "[" | append "]" end
     sed "s:foo:[\\&, \\&]:"   foreach substring "foo" then id; echo ", "; id end


## Using the framework from Haskell

The shell interface is basically only syntax on top of the underlying EDSL (embedded domain-specific language) in Haskell. If you require anything more than stringing together of existing components using existing combinators, you'll need to write Haskell code.

