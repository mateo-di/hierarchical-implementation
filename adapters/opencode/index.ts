import { Plugin } from "@opencode/plugin"

import { setupOpenCodeGate, type OpenCodeSessionInfo } from "./gate-client.ts"

export default Plugin.define({
  id: "hierarchical-implementation",
  async setup(ctx) {
    type SessionInput = Parameters<typeof ctx.session.get>[0]
    const sessionInput = (sessionID: string): SessionInput => ({ sessionID: sessionID as SessionInput["sessionID"] })

    await setupOpenCodeGate({
      session: {
        get: async (sessionID) => (await ctx.session.get(sessionInput(sessionID))) as OpenCodeSessionInfo,
      },
      tool: {
        hook: async (name, callback) => {
          if (name === "execute.before") {
            return ctx.tool.hook(name, (event) =>
              callback({
                tool: event.tool,
                sessionID: String(event.sessionID),
                agent: typeof (event as { agent?: unknown }).agent === "string" ? (event as { agent: string }).agent : undefined,
                id: String(event.id),
                input: event.input,
              }),
            )
          }
          return ctx.tool.hook(name, (event) =>
            callback({
              tool: event.tool,
              sessionID: String(event.sessionID),
              agent: typeof (event as { agent?: unknown }).agent === "string" ? (event as { agent: string }).agent : undefined,
              id: String(event.id),
              input: event.input,
              status: event.status,
              ...(event.status === "completed" ? { result: event.result } : {}),
            }),
          )
        },
      },
    })
  },
})
