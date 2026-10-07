#include <stdint.h>
typedef struct { uint32_t width; uint32_t height; uint32_t frames; } LiltImageInfo;
typedef int32_t (*LiltImageCallback)(const char *, const char *, uint32_t, const char *, LiltImageInfo *);
void lilt_init(const char *cache, const char *tools, LiltImageCallback image);
char *lilt_command(const char *input);
void lilt_free(char *pointer);
