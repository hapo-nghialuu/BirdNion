export type RevisionedSettings = {
  settingsRevision?: number;
};

/** Cross-window notification carrying the complete post-mutation snapshot.
 * Consumers must reject stale revisions before replacing local state. */
export const SETTINGS_SNAPSHOT_CHANGED_EVENT = "birdnion-settings-snapshot-changed";

export type SettingsSnapshotState<T extends RevisionedSettings> = {
  settings: T;
};

type SaveCommand<T extends RevisionedSettings> = (settings: T) => Promise<number>;

const saveTails = new WeakMap<object, Promise<void>>();

/**
 * Serialize whole-document saves for one in-memory Settings object and apply
 * the backend's optimistic-concurrency revision before the next save starts.
 * A missing/unsafe revision means settings were not loaded from the backend;
 * refusing locally prevents a fallback object from replacing real config.
 */
export function saveRevisionedSettings<T extends RevisionedSettings>(
  settings: T,
  command: SaveCommand<T>,
): Promise<number> {
  const prior = saveTails.get(settings) ?? Promise.resolve();
  const request = prior.then(async () => {
    const currentRevision = settings.settingsRevision;
    if (!Number.isSafeInteger(currentRevision) || (currentRevision ?? -1) < 0) {
      throw new Error("Settings are missing a valid revision; reload before saving");
    }
    const nextRevision = await command(settings);
    if (!Number.isSafeInteger(nextRevision) || nextRevision <= currentRevision!) {
      throw new Error("Backend returned an invalid settings revision");
    }
    const liveRevision = settings.settingsRevision;
    if (!Number.isSafeInteger(liveRevision) || liveRevision! < currentRevision!) {
      throw new Error("Settings revision changed invalidly while saving");
    }
    // A cross-window account/key mutation can deliver a newer complete
    // snapshot while this IPC is in flight. Never overwrite that revision
    // with the older save response; the next queued save must start from the
    // newest canonical state already applied to this object.
    settings.settingsRevision = Math.max(liveRevision!, nextRevision);
    return settings.settingsRevision;
  });
  saveTails.set(settings, request.then(() => undefined, () => undefined));
  return request;
}
