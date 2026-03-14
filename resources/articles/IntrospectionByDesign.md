## The compiler and all related functions are designed to be Introspective by Design

What am I talking about?

If you look in the program menu in Ed, you will see a number of functions for looking at the compilers output.

We can do this because our Editor contains the entire compiler, sorry about how huge that makes the download, but it does provide benefits.

The reports are very useful if you are writing or changing a compiler,  and it may be interesting for anyone who would like to see how the safe and friendly basic text is reduced to efficient machine code.

In this version most of the computer science is being conducted by LLVM, because we cant beat LLVM ourselves,
this is what gives FasterBASIC the right to the name.

None the less there are plenty of opportunities for us to slow LLVM code to a crawl. And there are also a few stages in the compiler where we know more about our program than LLVM does.

So if you enjoy compilers, want to improve this one, or are just interested in what 64bit code looks like, have fun :)



