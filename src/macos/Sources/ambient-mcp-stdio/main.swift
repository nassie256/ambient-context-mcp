// Phase 5 で StdioBridge の移植に置き換える暫定エントリポイント。
import Foundation
FileHandle.standardError.write("ambient-mcp-stdio placeholder\n".data(using: .utf8)!)
exit(1)
