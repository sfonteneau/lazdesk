#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
void *lazdesk_session_open_ex(char *, size_t);
void lazdesk_session_close(void *);
int main(void) {
    char err[512];
    void *h=lazdesk_session_open_ex(err,sizeof(err));
    assert(h==NULL);
    assert(strstr(err,"libsystemd.so.0"));
    assert(strstr(err,"sd_pid_get_session"));
    printf("PASS: precise missing system symbol: %s\n",err);
    return 0;
}
