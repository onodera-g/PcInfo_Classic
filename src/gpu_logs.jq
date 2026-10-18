# Input: dmesg as one raw string (-Rs); mode is cu or vram.
# Match PCI/domain or actual DRM card before using untagged legacy messages.
# The caller enables legacy messages only for its single-GPU condition.
def association_rank:
  [scan("(?i)(?:[0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]")
   | ascii_downcase | if length == 7 then "0000:" + . else . end] as $addresses
  | [scan("\\bcard[0-9]+\\b")] as $cards
  | if ($addresses | length) > 0 then
      if ($addresses | index($pci)) != null then 3 else 0 end
    elif ($cards | length) > 0 then
      if $card != "" and ($cards | index($card)) != null then 2 else 0 end
    elif $single == "1" then 1 else 0 end;

def cu_count:
  [split("\n")[]
   | select(test("amdgpu|active_cu_number|CU per SH"; "i"))
   | association_rank as $rank | select($rank > 0)
   | if test("active_cu_number[[:space:]:=]+[0-9]+") then
       capture("active_cu_number[[:space:]:=]+(?<count>[0-9]+)")
       | {rank: $rank, kind: 2, count: (.count | tonumber)}
     elif test("[0-9]+ CU per SH") then
       capture("(?<count>[0-9]+) CU per SH")
       | {rank: $rank, kind: 1, count: (.count | tonumber)}
     else empty end
   | select(.count > 0)]
  | if length == 0 then empty
    else (map([.kind, .rank]) | max) as $best
      | map(select([.kind, .rank] == $best)) | last.count
    end;

def vram_lines:
  [split("\n")[] | select(test("VRAM")) | . as $line
   | association_rank as $rank | select($rank > 0) | {line: $line, rank: $rank}]
  | if length == 0 then empty
    else (map(.rank) | max) as $best | .[] | select(.rank == $best) | .line
    end;

if $mode == "cu" then cu_count
elif $mode == "vram" then vram_lines
else error("Unsupported GPU log mode: " + $mode)
end
