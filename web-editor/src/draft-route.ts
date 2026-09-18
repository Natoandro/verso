const draftParameter = "draft";
const maximumDraftIdLength = 160;

export type LocationLike = Pick<Location, "href">;
export type HistoryLike = Pick<History, "replaceState">;

export function isDraftId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maximumDraftIdLength && !/[\u0000-\u001f\u007f]/.test(value);
}

export function readDraftId(locationLike: LocationLike = window.location): string | null {
  const value = new URL(locationLike.href).searchParams.get(draftParameter);
  return isDraftId(value) ? value : null;
}

export function draftScopedUrl(draftId: string, href: string = window.location.href): string {
  if (!isDraftId(draftId)) throw new TypeError("Invalid local draft ID");
  const url = new URL(href);
  url.searchParams.set(draftParameter, draftId);
  return `${url.pathname}${url.search}${url.hash}`;
}

export function ensureDraftScopedUrl(
  draftId: string,
  locationLike: LocationLike = window.location,
  historyLike: HistoryLike = window.history,
): boolean {
  if (readDraftId(locationLike) === draftId) return false;
  historyLike.replaceState(null, "", draftScopedUrl(draftId, locationLike.href));
  return true;
}
