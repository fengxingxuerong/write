#!/usr/bin/env bash
# 墨匠 · 全题材样章批量测试脚本
# 串行跑 11 种题材（玄幻已有 sample_imnovel 基线），每本 2 章短篇样章
# 用法：bash run_all_genres.sh   （需先 source .env.local 注入密钥）
set -a
source /d/novel-writer/.env.local
set +a

GENRES="xianxia dushi dushi_yineng kehuan moshi youxi xuanyi wuxia lishi junshi tiyu"
declare -A NAME=(
  [xianxia]=仙侠 [dushi]=都市 [dushi_yineng]=都市异能 [kehuan]=科幻 [moshi]=末世
  [youxi]=游戏 [xuanyi]=悬疑 [wuxia]=武侠 [lishi]=历史 [junshi]=军事 [tiyu]=体育
)

cd /d/novel-writer/scripts || exit 1

for g in $GENRES; do
  echo "=================================================="
  echo "[$(date '+%H:%M:%S')] 开始题材：${NAME[$g]} ($g)"
  echo "=================================================="
  python -u novel_pipeline.py \
    --total-words 4000 \
    --max-chapters 2 \
    --genre "${NAME[$g]}" \
    --chapter-wait 1 \
    --output "D:/novel-writer/data/generated/genre_${g}.jsonl" \
    > "D:/novel-writer/data/generated/genre_${g}.log" 2>&1
  echo "[$(date '+%H:%M:%S')] ${NAME[$g]} 完成，退出码 $?"
done

echo "=================================================="
echo "[$(date '+%H:%M:%S')] 全部题材跑完"
echo "=================================================="
