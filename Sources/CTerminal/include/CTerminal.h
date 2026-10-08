#ifndef DNS_MANAGER_TERMINAL_H
#define DNS_MANAGER_TERMINAL_H
int dm_start(void);
void dm_finish(void);
int dm_rows(void);
int dm_columns(void);
int dm_key(void);
void dm_clear(void);
void dm_present(void);
void dm_text(int row, int column, int width, const char *text, int style);
void dm_box(int row, int column, int height, int width, int focused);
#endif
