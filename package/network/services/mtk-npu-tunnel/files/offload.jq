# The kernel samples a bounded window of flow decisions. A synchronized
# tunnel is not itself a PPE binding. Match the current tunnel generation.
def bindings($t):
  [.entries[] | select(.tunnel == $t.index and .tunnel_generation == $t.generation
                       and .binding_verified == true and .npu_path == true)]
  | unique_by([.ppe, .foe, .foe_generation]);

def flow_line:
  "  PPE \(.ppe) / FOE \(.foe)：" +
  (if .hardware_count_available == true and (.hardware_packets | type) == "string"
      and (.hardware_bytes | type) == "string" then
     "\(.hardware_packets) 包，\(.hardware_bytes) 字节"
   else "绑定已验证，尚无硬件计数样本" end);

if ((.schema != 2 and .schema != 3 and .schema != 4) or
    (.npu | type) != "object" or (.tunnels.entries | type) != "array")
then error("TOPS 状态格式不可用") else . end
| .flow_diagnostics as $diag
| (.npu.coverage == "complete" and .npu.firmware_ready == true and .npu.mcu_alive == true) as $ready
| ($diag.source == "hnat_owner_ledger" and $diag.available == true and
   $diag.read_coverage == "complete" and $diag.collection_enabled == true and
   ($diag.entries | type) == "array") as $have_flows
| [.tunnels.entries[] | select($ifindex == 0 or .ifindex == $ifindex)] as $tunnels
| (if .npu.coverage != "complete" then "NPU 固件状态不可用"
   elif $ready then
     "NPU 固件就绪，已注册 \(.npu.registered_tunnel_types) 种隧道协议"
   else "NPU 固件或 MCU 尚未就绪" end),
  (if $have_flows then empty else "PPE 流诊断不可用或已关闭" end),
  (if .tunnels.coverage != "complete" then
     "隧道快照不完整（\(.tunnels.coverage // "unknown")）"
   elif ($tunnels | length) == 0 then
     "当前未记录匹配的 TOPS 隧道"
   else empty end),
  ($tunnels[] as $t
   | "#\($t.index) \($t.protocol) · ifindex \($t.ifindex) · \($t.local_address) → \($t.remote_address) · " +
     (if $t.synchronized then "参数已同步" else "参数未同步" end),
     (if $ready and $have_flows and .tunnels.coverage == "complete" and $t.synchronized then
        $diag | bindings($t) |
        if length == 0 then "  近期样本中未观察到已验证的 NPU/PPE 绑定"
        else .[] | flow_line end
      else empty end))
