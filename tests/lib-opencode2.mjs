// Drive a V2 plugin's subscribed events with the existing Node fixture calls.
export async function setupOpenCodePlugin(definition, { client, directory }) {
  const listeners = [];
  const ctx = {
    location: { directory },
    session: {
      prompt: async ({ sessionID, text, delivery }) => {
        if (delivery !== "queue") {
          console.error(`OpenCode plugin prompt used delivery ${JSON.stringify(delivery)} instead of "queue"`);
          process.exitCode = 1;
          throw new Error(`unexpected prompt delivery: ${delivery}`);
        }
        return client.session.promptAsync({
          path: { id: sessionID },
          body: { parts: [{ type: "text", text }] },
        });
      },
    },
    event: {
      subscribe({ types, signal }) {
        const listener = { types, signal, queue: [], wake: null };
        listeners.push(listener);
        return {
          async *[Symbol.asyncIterator]() {
            while (!signal.aborted) {
              const item = listener.queue.shift() ?? await new Promise((resolve) => {
                listener.wake = resolve;
                signal.addEventListener("abort", () => resolve(null), { once: true });
              });
              if (!item) return;
              yield item.event;
              item.done();
            }
          },
        };
      },
    },
  };
  const cleanup = await definition.setup(ctx);
  return {
    event: async ({ event }) => {
      const type = event.type === "session.idle" ? "session.execution.succeeded" : event.type;
      const delivered = listeners.filter(({ types }) => types.includes(type)).map((listener) => new Promise((resolve) => {
        const item = { event: { type, data: event.properties ?? event.data }, done: resolve };
        if (listener.wake) {
          const wake = listener.wake;
          listener.wake = null;
          wake(item);
        } else {
          listener.queue.push(item);
        }
      }));
      await Promise.all(delivered);
    },
    cleanup,
  };
}
