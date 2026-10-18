# smartctl 7.4 JSON. Exit bits: smartctl(8), EXIT STATUS.
# Unknown is deliberate: a missing/failed overall check must never imply Good.
def number: if type == "number" and . >= 0 then . else null end;
def count: number | if . != null and floor == . then . else null end;
def bit($code; $mask): (($code / $mask | floor) % 2) == 1;
def attr($id): [.ata_smart_attributes.table[]? | select(.id == $id)][0] // {};
def raw($id): attr($id).raw.value | count;
def remaining:
  (.nvme_smart_health_information_log.percentage_used | count) as $used
  | if $used != null then [0, 100 - $used] | max
    else
      # These smartmontools database names express a normalized remaining %.
      # Wear_Leveling_Count and Available_Reserved_Space are not lifetime %.
      [.ata_smart_attributes.table[]?
       | select(.name == "Media_Wearout_Indicator" or .name == "SSD_Life_Left"
                or .name == "Percent_Lifetime_Remain"
                or .name == "Percent_Lifetime_Remaining")
       | .value | count | select(. != null and . <= 100)] as $values
      | if ($values | length) > 0 then $values | min
        else [.ata_smart_attributes.table[]?
              | select(.name == "Perc_Rated_Life_Used") | .raw.value | count
              | select(. != null and . <= 100) | 100 - .] | .[0]
        end
    end;
def host_writes:
  (.nvme_smart_health_information_log.data_units_written | count) as $units
  | if $units != null then $units * 512000
    else [.ata_smart_attributes.table[]?
          | (.raw.value | count) as $value | select($value != null)
          | if (.name // "" | test("^(Host_Writes_32MiB|Host_Write_32MiB)$"; "i")) then $value * 33554432
            elif (.name // "" | test("^(Host_Writes_GiB|Total_Writes_GiB|Lifetime_Writes_From_Host|Total_Host_Writes)$"; "i")) then $value * 1073741824
            elif (.name // "" | test("^(Total_LBAs_Written|LBAs_Written)$"; "i")) then $value * 512
            else empty end] | .[0]
    end;
(.smart_status.passed) as $passed
| (.smartctl.exit_status | count) as $reported_exit
| (if $reported_exit != null and $reported_exit <= 255 then $reported_exit else $exit_status end) as $code
| def hasbit($mask): bit($code; $mask) or bit($exit_status; $mask);
  (.nvme_smart_health_information_log // {}) as $nvme
| remaining as $life
| [if $passed == false or hasbit(8) then "SMART reports failing health" else empty end,
   if hasbit(16) then "SMART attribute is below its failure threshold" else empty end,
   if ($nvme.critical_warning | count // 0) > 0 then "NVMe critical warning is set" else empty end,
   if (raw(187) // 0) > 0 then "Reported uncorrectable errors" else empty end,
   if any(.ata_smart_attributes.table[]?; .when_failed == "now" and .flags.prefailure == true)
     then "Prefailure attribute is failing now" else empty end,
   if $life != null and $life == 0 then "Rated remaining life is exhausted" else empty end] as $bad
| [if (raw(5) // 0) > 0 then "Reallocated sectors" else empty end,
   if (raw(197) // 0) > 0 then "Pending sectors" else empty end,
   if (raw(198) // 0) > 0 or ($nvme.media_errors | count // 0) > 0 then "Media errors" else empty end,
   if hasbit(32) then "SMART attribute failed in the past" else empty end,
   if hasbit(64) then "Device error log contains errors" else empty end,
   if hasbit(128) then "Self-test log contains errors" else empty end,
   if $life != null and $life > 0 and $life <= 10 then "Rated remaining life is low" else empty end] as $caution
| [if hasbit(1) or hasbit(2) or hasbit(4) then "SMART data could not be read completely" else empty end,
   if ($passed | type) != "boolean" then "Overall SMART health is unavailable" else empty end] as $unknown
| (if ($bad | length) > 0 then "Bad"
   elif ($unknown | length) > 0 then "Unknown"
   elif ($caution | length) > 0 then "Caution" else "Good" end) as $status
| {
    health_status: $status,
    reason: (if $status == "Good" then "SMART health passed; no selected warning indicators"
             else ($bad + $unknown + $caution | unique | join("; ")) end),
    model: (.model_name // .scsi_model_name // .product // null),
    remaining_percent: $life,
    temperature: (.temperature.current | number),
    total_host_writes_bytes: host_writes,
    power_cycles: (.power_cycle_count | count),
    power_on_hours: (.power_on_time.hours | count),
    critical_warning: ($nvme.critical_warning | count),
    available_spare: ($nvme.available_spare | count),
    spare_threshold: ($nvme.available_spare_threshold | count),
    reallocated: raw(5), pending: raw(197), reported_uncorrectable: raw(187),
    media_errors: (if ($nvme.media_errors | count) != null then $nvme.media_errors | count else raw(198) end)
  }
