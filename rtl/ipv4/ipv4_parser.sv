// TODO: Implement IPv4 header parser
// TODO: Extract version, IHL, TOS, total length, protocol, source IP, dest IP
// TODO: Validate header checksum
// TODO: Implement incremental checksum calculation for pipeline optimization
// TODO: Pipeline stage 2: Parse IPv4 header (20-60 bytes, typically 20)
// TODO: Forward payload to UDP parser when protocol = 0x11 (UDP)
// TODO: Handle IP fragmentation flags (drop fragmented packets or handle)
