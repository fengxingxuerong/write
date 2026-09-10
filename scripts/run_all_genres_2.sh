#!/usr/bin/env bash
# 墨匠 · 剩余题材样章批量补全脚本（第二批）
# 串行跑 7 种题材（玄幻/仙侠/都市/悬疑/末世已测），每本 2 章短篇样章
# 用法：bash run_all_genres_2.sh   （需先 source .env.local 注入密钥）
set -a
source /d/novel-writer/.env.local
set +a

GENRES="kehuan youxi wuxia lishi junshi tiyu dushi_yineng"
declare -A NAME=(
  [kehuan]=科幻 [youxi]=游戏 [wuxia]=武侠 [lishi]=历史
  [junshi]=军事 [tiyu]=体育 [dushi_yineng]=都市异能
)

cd /d/novel-writer/scripts || exit 1

for g in $GENRES; do
  echo "=================================================="
  echo "[$(date '+%H:%M:%S')] 开始题材：${NAME[$g]} ($g)"
  echo "=================================================="
  python -u novel_pipeline.py \
    --total-words 6000 \
    --max-chapters 2 \
    --genre "${NAME[$g]}" \
    --chapter-wait 1 \
    --output "D:/novel-writer/data/generated/genre_${g}_full.jsonl" \
    > "D:/novel-writer/data/generated/genre_${g}_full.log" 2>&1
  echo "[$(date '+%H:%M:%S')] ${NAME[$g]} 完成，退出码 $?"
done

echo "=================================================="
echo "[$(date '+%H:%M:%S')] 全部题材补全完成"
echo "=================================================="
