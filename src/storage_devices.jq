# Normalize lsblk -d -b -J records without parsing JSON with text patterns.
# Keep source order and the same five fields used by PC Info.
def text_value: if . == null then "" else tostring end;

if type != "object" then error("Invalid lsblk inventory")
elif (.blockdevices | type) != "array" then error("Missing lsblk blockdevices")
else
  .blockdevices[]
  | select(type == "object")
  | {name: (.name | text_value), model: (.model | text_value),
     size: (.size | text_value), tran: (.tran | text_value), type: (.type | text_value)}
  | select(.name != "" and .type != "")
end
