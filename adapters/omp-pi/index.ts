import { registerOmpPiGate, type OmpExtensionAPI } from "./gate-client.ts"

export default function hierarchicalImplementationGate(pi: OmpExtensionAPI): void {
  registerOmpPiGate(pi)
}
