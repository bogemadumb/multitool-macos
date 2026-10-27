#!/bin/bash
# Аварийный возврат: включает обратно все отключённые дисплеи.
# Запускается двойным кликом. Не зависит от собранного monitortoggle —
# компилирует себе временную программу заново.
cd "$(mktemp -d)"
cat > restore.c <<'EOF'
#include <stdio.h>
#include <ApplicationServices/ApplicationServices.h>
extern CGError CGSGetDisplayList(uint32_t, CGDirectDisplayID*, uint32_t*);
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);
int main(void){
  CGDirectDisplayID ids[16]; uint32_t n=0;
  CGSGetDisplayList(16, ids, &n);
  CGDisplayConfigRef cfg;
  if(CGBeginDisplayConfiguration(&cfg)!=kCGErrorSuccess){ printf("не удалось начать\n"); return 1; }
  int touched=0;
  for(uint32_t i=0;i<n;i++)
    if(!CGDisplayIsOnline(ids[i]) && CGDisplayVendorNumber(ids[i])!=0){
      CGSConfigureDisplayEnabled(cfg, ids[i], true); touched++;
      printf("возвращаю дисплей %u\n", ids[i]);
    }
  if(!touched){ CGCancelDisplayConfiguration(cfg); printf("Отключённых дисплеев нет — всё уже в порядке.\n"); return 0; }
  printf("результат: %d\n", CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently));
  return 0;
}
EOF
clang restore.c -o restore -framework ApplicationServices && ./restore
echo
echo "Если монитор всё равно не вернулся — вынь и вставь переходник USB-C."
echo "Окно можно закрыть."
