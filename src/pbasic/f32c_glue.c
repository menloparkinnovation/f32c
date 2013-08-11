
#include <sys/param.h>

#include <unistd.h>
#include <stdlib.h>
#include <signal.h>
#include <setjmp.h>
#include <time.h>
#include <stdio.h>


int errno;

static char *freep = (void *) 0x80080000;


void memcpy(void)
{
}


void *sbrk(intptr_t p)
{

	if (p != 0)
		freep = freep + p;

printf("sbrk(%d) new: %p\n", p, freep);
	return (freep);
}


int
setjmp(jmp_buf env)
{

	return (_setjmp(env));
}


void
longjmp(jmp_buf env, int val)
{

	_longjmp(env, val);
}


int *__error(void)
{

	return (&errno);
}

char *
getenv(const char *name __unused)
{

	return ("");
}

pid_t
getpid(void)
{

	return (0);
}


int
kill(pid_t pid __unused, int sig __unused)
{

	return (-1);
}


sig_t
signal(int sig, sig_t func)
{

	return (SIG_ERR);
}


void
_exit(int status)
{

	do {
		exit (status);
	} while (1);
}


int
syscall(int number __unused, ...)
{

	return (-1);
}


time_t
time(time_t *tloc)
{
	time_t res = 0;

	if (tloc != NULL)
		*tloc = res;
	return (res);
}


static struct tm t;

struct tm *
localtime(const time_t *clock __unused)
{

	return (&t);
}


char *
ctime(const time_t *clock __unused)
{

	return ("");
}


void
srand(unsigned seed __unused)
{
}


void
set_term(void)
{
}


void
setu_term(void)
{
}


void
rset_term(int arg __unused)
{
}
