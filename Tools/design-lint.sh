#!/bin/bash
#
# Checks the notch's views against the design scale, and lists every literal
# that is off it. Exits 1 when there are any.
#
# The scale exists so that the interface reads as one thing: before it, the
# notch used 26 text sizes (9, 9.5, 10 and 10.5 side by side), 25 corner radii
# and 37 strengths of white. The values:
#
#   text size       7 8 9 10 11 12 13 14 16 18 20 22 26 32
#   weight          regular medium semibold bold
#   corner radius   1 2 4 6 8 12 16 24   (a nested corner = outer − the gap)
#   spacing/padding 0, 1 (a hairline), or an even number
#   white           .04 .08 .12 .16 .24 (surfaces)  .35 .5 .7 .85 .95 (ink)
#   shadow          black only: a shadow in a colour is a glow
#
# Left out on purpose: the games, the drawn art (the cat, the mascots, the
# weather scenes), the settings window, the glass material itself, and the
# teleprompter and terminal, whose text sizes are the user's.
#
set -uo pipefail
cd "$(dirname "$0")/.."

find Sources/Views Sources/Extras -name '*.swift' \
  | grep -vE 'GameView|Breakout|Dino|PixelWeatherView|Cat/CatArt|Cat/CatPreviewScenes|DecorMascots|NotchGlass|DecorGlass|Teleprompter/|Terminal/|Settings\.swift$' \
  | sort \
  | xargs perl -ne '
      BEGIN {
        %type = map { $_ => 1 } qw(7 8 9 10 11 12 13 14 16 18 20 22 26 32);
        %radius = map { $_ => 1 } qw(1 2 4 6 8 12 16 24);
        %white = map { $_ => 1 } qw(0.04 0.08 0.12 0.16 0.24 0.35 0.5 0.7 0.85 0.95 1);
        $bad = 0;
      }
      sub flag { my ($what) = @_; print "$ARGV:$.: $what\n"; $bad++ }
      while (/system\(size: (\d+(?:\.\d+)?)[,)]/g) { flag("text size $1") unless $type{$1 + 0} }
      while (/cornerRadius: (\d+(?:\.\d+)?)[,)]/g) { flag("corner radius $1") unless $radius{$1 + 0} }
      while (/\bspacing: (\d+(?:\.\d+)?)[,)]/g) { flag("spacing $1") unless $1 == 0 || $1 == 1 || ($1 == int($1) && $1 % 2 == 0) }
      while (/\.padding\((?:\.[a-zA-Z]+, )?(\d+(?:\.\d+)?)\)/g) { flag("padding $1") unless $1 == 0 || $1 == 1 || ($1 == int($1) && $1 % 2 == 0) }
      while (/\.white\.opacity\((\d+(?:\.\d+)?)\)/g) { flag("white $1") unless $white{$1 + 0} }
      flag("weight .$1") while /weight: \.(heavy|black|light|thin|ultraLight)\b/g;
      flag("coloured shadow") if /\.shadow\(color: / && !/\.shadow\(color: (?:Color)?\.(?:black|clear)/;
      close ARGV if eof;
      END { if ($bad) { print "\n$bad value(s) off the design scale\n"; exit 1 } print "OK: every value is on the design scale\n" }
    '
