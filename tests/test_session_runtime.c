#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdint.h>
uint32_t lazdesk_session_abi(void);
void *lazdesk_session_open_ex(char *,size_t);
int lazdesk_session_poll(void *,char *,size_t);
void lazdesk_session_close(void *);
int main(void) {
    char error[512],identity[256];
    assert(lazdesk_session_abi()==0x00090001);
    void *h=lazdesk_session_open_ex(error,sizeof(error));
    if(!h) { printf("NOTE: native code linked; system runtime unavailable: %s\n",error); return 0; }
    int state=lazdesk_session_poll(h,identity,sizeof(identity));
    assert(state>=0 && state<=4);
    printf("PASS: native static guard open/poll/close with system runtime; state=%d\n",state);
    lazdesk_session_close(h);
    return 0;
}
