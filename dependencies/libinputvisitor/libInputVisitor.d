/++
Copyright (C) 2012 Nick Sabalausky <http://semitwist.com/contact>

This program is free software. It comes without any warranty, to
the extent permitted by applicable law. You can redistribute it
and/or modify it under the terms of the Do What The Fuck You Want
To Public License, Version 2, as published by Sam Hocevar. See
http://www.wtfpl.net/ for more details.

	DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE 
				Version 2, December 2004 

Copyright (C) 2004 Sam Hocevar <sam@hocevar.net> 

Everyone is permitted to copy and distribute verbatim or modified 
copies of this license document, and changing it is allowed as long 
as the name is changed. 

		DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE 
TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION 

0. You just DO WHAT THE FUCK YOU WANT TO.
+/

/++
Should work with DMD 2.059 and up

For more info on this, see:
http://semitwist.com/articles/article/view/combine-coroutines-and-input-ranges-for-dead-simple-d-iteration
+/

import core.thread;

class InputVisitor(Obj, Elem) : Fiber
{
	bool started = false;
	Obj obj;
	this(Obj obj)
	{
		this.obj = obj;

		version(Windows) // Issue #1
		{
			import core.sys.windows.windows : SYSTEM_INFO, GetSystemInfo;
			SYSTEM_INFO info;
			GetSystemInfo(&info);
			auto PAGESIZE = info.dwPageSize;

			super(&run, PAGESIZE * 16);
		}
		else
			super(&run);
	}

	this(Obj obj, size_t stackSize)
	{
		this.obj = obj;
		super(&run, stackSize);
	}

	private void run()
	{
		obj.visit(this);
	}
	
	private void ensureStarted()
	{
		if(!started)
		{
			call();
			started = true;
		}
	}
	
	// Member 'front' must be a function due to DMD Issue #5403
	private Elem _front = Elem.init; // Default initing here avoids "Error: field _front must be initialized in constructor"
	@property Elem front()
	{
		ensureStarted();
		return _front;
	}
	
	void popFront()
	{
		ensureStarted();
		call();
	}
	
	@property bool empty()
	{
		ensureStarted();
		return state == Fiber.State.TERM;
	}
	
	void yield(Elem elem)
	{
		_front = elem;
		Fiber.yield();
	}
}

template inputVisitor(Elem)
{
	@property InputVisitor!(Obj, Elem) inputVisitor(Obj)(Obj obj)
	{
		return new InputVisitor!(Obj, Elem)(obj);
	}

	@property InputVisitor!(Obj, Elem) inputVisitor(Obj)(Obj obj, size_t stackSize)
	{
		return new InputVisitor!(Obj, Elem)(obj, stackSize);
	}
}
