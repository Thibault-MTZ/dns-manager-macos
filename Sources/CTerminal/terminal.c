#include "CTerminal.h"
#include <ncurses.h>
#include <locale.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <signal.h>
#include <unistd.h>

static int running = 0;
void dm_finish(void) { if (running) { running = 0; endwin(); } }
static void terminate_terminal(int sig) { dm_finish(); _exit(128 + sig); }
int dm_start(void) {
    setlocale(LC_ALL, "");
    if (MB_CUR_MAX < 2) setlocale(LC_ALL, "en_US.UTF-8");
    if (!initscr()) return 0;
    running = 1;
    atexit(dm_finish);
    signal(SIGTERM, terminate_terminal);
    raw(); noecho(); keypad(stdscr, TRUE); curs_set(0); timeout(100);
    set_escdelay(35);
    if (has_colors()) {
        start_color(); use_default_colors();
        init_pair(1, COLOR_WHITE, -1);
        init_pair(2, COLOR_GREEN, -1);
        init_pair(3, COLOR_YELLOW, -1);
        init_pair(4, COLOR_RED, -1);
        init_pair(5, COLOR_CYAN, -1);
        init_pair(6, COLOR_WHITE, COLOR_BLUE);
        init_pair(7, COLOR_BLACK, COLOR_CYAN);
    }
    return 1;
}
int dm_rows(void) { return LINES; }
int dm_columns(void) { return COLS; }
void dm_clear(void) { erase(); }
void dm_present(void) { refresh(); }
int dm_key(void) {
    int key = getch();
    switch (key) {
        case ERR: return -1;
        case KEY_UP: return -1001;
        case KEY_DOWN: return -1002;
        case KEY_LEFT: return -1003;
        case KEY_RIGHT: return -1004;
        case KEY_BTAB: return -1005;
        case KEY_PPAGE: return -1006;
        case KEY_NPAGE: return -1007;
        case KEY_HOME: return -1008;
        case KEY_DC: return -1009;
        case KEY_RESIZE: return -1010;
        case KEY_BACKSPACE: return 127;
        case KEY_ENTER: return 10;
    }
    if (key >= 128 && key <= 255) {
        char bytes[5] = {(char)key, 0, 0, 0, 0};
        int count = (key & 0xe0) == 0xc0 ? 2 : (key & 0xf0) == 0xe0 ? 3 : (key & 0xf8) == 0xf0 ? 4 : 1;
        for (int i = 1; i < count; i++) {
            int next = getch();
            if (next < 0 || next > 255) return -1;
            bytes[i] = (char)next;
        }
        wchar_t character; mbstate_t state = {0};
        size_t length = mbrtowc(&character, bytes, count, &state);
        if (length > 0 && length <= (size_t)count) return (int)character;
        return -1;
    }
    return key;
}
void dm_text(int row, int column, int width, const char *text, int style) {
    if (row < 0 || row >= LINES || column < 0 || column >= COLS || width <= 0) return;
    if (width > COLS - column) width = COLS - column;
    int pair = style >= 1 && style <= 7 ? style : 1;
    attrset(COLOR_PAIR(pair) | (pair == 5 || pair == 6 || pair == 7 ? A_BOLD : 0));
    mvhline(row, column, ' ', width);
    move(row, column);
    const char *cursor = text;
    int used = 0;
    mbstate_t state = {0};
    while (*cursor && used < width) {
        wchar_t character;
        size_t length = mbrtowc(&character, cursor, strlen(cursor), &state);
        if (length == (size_t)-1 || length == (size_t)-2 || length == 0) break;
        int cells = wcwidth(character);
        if (cells < 0) { addch(' '); used++; }
        else {
            if (used + cells > width) break;
            addnstr(cursor, (int)length); used += cells;
        }
        cursor += length;
    }
    attrset(A_NORMAL);
}
void dm_box(int row, int column, int height, int width, int focused) {
    if (width < 2 || height < 2 || row < 0 || column < 0 || row + height > LINES || column + width > COLS) return;
    int style = focused ? 5 : 1;
    for (int x = column + 1; x < column + width - 1; x++) {
        dm_text(row, x, 1, "─", style);
        dm_text(row + height - 1, x, 1, "─", style);
    }
    for (int y = row + 1; y < row + height - 1; y++) {
        dm_text(y, column, 1, "│", style);
        dm_text(y, column + width - 1, 1, "│", style);
    }
    dm_text(row, column, 1, "╭", style);
    dm_text(row, column + width - 1, 1, "╮", style);
    dm_text(row + height - 1, column, 1, "╰", style);
    dm_text(row + height - 1, column + width - 1, 1, "╯", style);
}
