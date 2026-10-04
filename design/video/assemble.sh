#!/bin/zsh
set -e
F=/opt/homebrew/bin/ffmpeg
mkdir -p clips
scenes=(01-title:3.9 02-first:3.4 03-speed:4.4 04-overview:3.9 05-treemap:3.9 06-sunburst:3.4 07-find:3.9 08-biggest:3.4 09-duplicates:3.4 10-developer:3.9 11-media:3.4 12-safe:3.4 13-cleanup:3.9 14-palette:3.4 15-themes:4.4 16-rescan:3.9 17-private:3.9 18-outro:5.0)
for s in $scenes; do [[ -f clips/${s%%:*}.mp4 && -n $SKIP ]] && continue
  id=${s%%:*}; d=${s##*:}
  $F -loglevel error -y -loop 1 -framerate 30 -t $d -i scenes/$id-bg.png -loop 1 -framerate 30 -t $d -i scenes/$id-fg.png -filter_complex \
  "[0]format=yuv444p,scale=w='trunc(2560*(1+0.045*t/$d)/2)*2':h=-2:eval=frame:flags=bicubic,crop=2560:1440:'(iw-2560)/2':'(ih-1440)/2',scale=1920:1080:flags=lanczos,setsar=1[b];\
   [1]format=rgba,scale=1920:1080:flags=lanczos,fade=in:st=0.2:d=0.55:alpha=1[f];\
   [b][f]overlay=x=0:y='22*max(0,1-(t-0.2)/0.55)*max(0,1-(t-0.2)/0.55)':eval=frame,format=yuv420p[v]" \
   -map "[v]" -c:v libx264 -preset slow -crf 14 -r 30 clips/$id.mp4
  echo "$id"
done
# crossfade chain
inputs=(); filt=""; prev="0:v"; off=0; i=0; X=0.4
for s in $scenes; do inputs+=(-i clips/${s%%:*}.mp4); done
for s in $scenes; do
  d=${s##*:}
  if (( i > 0 )); then
    filt+="[$prev][${i}:v]xfade=transition=fade:duration=$X:offset=${off}[x$i];"; prev="x$i"
  fi
  off=$(( off + d - X )); i=$(( i + 1 ))
done
total=$(( off + X ))
filt+="[$prev]fade=out:st=$(( total - 0.6 )):d=0.6[vout]"
$F -loglevel error -y $inputs -i music.wav -filter_complex "$filt;[${i}:a]atrim=0:$total,afade=out:st=$(( total - 2.5 )):d=2.5[aout]" \
  -map "[vout]" -map "[aout]" -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 192k freedisk-demo.mp4
echo total=$total
