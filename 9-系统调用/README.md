kill 系统调用

1. 
common/include/uapi/asm-generic/unistd.h
```cpp
#define __NR_kill 129
__SYSCALL(__NR_kill, sys_kill)
```

2. 
common/arch/arm64/kernel/sys32.c
```cpp
#undef __SYSCALL
#define __SYSCALL(nr, sym)	[nr] = sym,

/*
 * The sys_call_table array must be 4K aligned to be accessible from
 * kernel/entry.S.
 */
void * const compat_sys_call_table[__NR_compat_syscalls] __aligned(4096) = {
	[0 ... __NR_compat_syscalls - 1] = sys_ni_syscall,
#include <asm/unistd32.h>
};
```

3. 

common/kernel/signal.c
```cpp
/**
 *  sys_kill - send a signal to a process
 *  @pid: the PID of the process
 *  @sig: signal to be sent
 */
SYSCALL_DEFINE2(kill, pid_t, pid, int, sig)
{
	struct siginfo info;

	prepare_kill_siginfo(sig, &info);

	return kill_something_info(sig, &info, pid);
}
```

4. 

common/include/linux/syscalls.h
```cpp
#define SYSCALL_DEFINE2(name, ...) SYSCALL_DEFINEx(2, _##name, __VA_ARGS__)

#define SYSCALL_DEFINEx(x, sname, ...)				\
	SYSCALL_METADATA(sname, x, __VA_ARGS__)			\
	__SYSCALL_DEFINEx(x, sname, __VA_ARGS__)

#define __PROTECT(...) asmlinkage_protect(__VA_ARGS__)
#define __SYSCALL_DEFINEx(x, name, ...)					\
	asmlinkage long sys##name(__MAP(x,__SC_DECL,__VA_ARGS__))	\
		__attribute__((alias(__stringify(SyS##name))));		\
	static inline long SYSC##name(__MAP(x,__SC_DECL,__VA_ARGS__));	\
	asmlinkage long SyS##name(__MAP(x,__SC_LONG,__VA_ARGS__));	\
	asmlinkage long SyS##name(__MAP(x,__SC_LONG,__VA_ARGS__))	\
	{								\
		long ret = SYSC##name(__MAP(x,__SC_CAST,__VA_ARGS__));	\
		__MAP(x,__SC_TEST,__VA_ARGS__);				\
		__PROTECT(x, ret,__MAP(x,__SC_ARGS,__VA_ARGS__));	\
		return ret;						\
	}								\
	static inline long SYSC##name(__MAP(x,__SC_DECL,__VA_ARGS__))
```

其中__MAP的宏

```cpp
#define __MAP0(m,...)
#define __MAP1(m,t,a) m(t,a)
#define __MAP2(m,t,a,...) m(t,a), __MAP1(m,__VA_ARGS__)
#define __MAP3(m,t,a,...) m(t,a), __MAP2(m,__VA_ARGS__)
#define __MAP4(m,t,a,...) m(t,a), __MAP3(m,__VA_ARGS__)
#define __MAP5(m,t,a,...) m(t,a), __MAP4(m,__VA_ARGS__)
#define __MAP6(m,t,a,...) m(t,a), __MAP5(m,__VA_ARGS__)
#define __MAP(n,...) __MAP##n(__VA_ARGS__)

#define __SC_DECL(t, a)	t a
#define __TYPE_IS_L(t)	(__same_type((t)0, 0L))
#define __TYPE_IS_UL(t)	(__same_type((t)0, 0UL))
#define __TYPE_IS_LL(t) (__same_type((t)0, 0LL) || __same_type((t)0, 0ULL))
#define __SC_LONG(t, a) __typeof(__builtin_choose_expr(__TYPE_IS_LL(t), 0LL, 0L)) a
#define __SC_CAST(t, a)	(t) a
#define __SC_ARGS(t, a)	a
#define __SC_TEST(t, a) (void)BUILD_BUG_ON_ZERO(!__TYPE_IS_LL(t) && sizeof(t) > sizeof(long))
```

__MAP的第一个参数是参数个数，展开后就是__MAP0 __MAP1等等，第二个参数是对应的宏操作，第三个是参数。

到__MAP2后会递归展开 __MAP1 __MAP0，这几个宏第一参数是宏操作，第二个是参数类型，第三个参数是参数名，第四个是剩下的参数

因而

```cpp
SYSCALL_DEFINE2(kill, pid_t, pid, int, sig)
{
	struct siginfo info;

	prepare_kill_siginfo(sig, &info);

	return kill_something_info(sig, &info, pid);
}
```

展开后

```cpp
asmlinkage long sys_kill(pid_t pid, int sig)
    __attribute__((alias(__stringify(SySkill))));

static inline long SYSCkill(pid_t pid, int sig);
asmlinkage long SySkill(long pid, long sig);
asmlinkage long SySkill(long pid, long sig)
{
	long ret = SYSCkill((pid_t) pid, (int) sig);
	__MAP(x,__SC_TEST,__VA_ARGS__);				\\ ??
	__PROTECT(x, ret,__MAP(x,__SC_ARGS,__VA_ARGS__));	??
	return ret;	
}
static inline long SYSCkill(pid_t pid, int sig)
{
	struct siginfo info;

	prepare_kill_siginfo(sig, &info);

	return kill_something_info(sig, &info, pid);
}
```