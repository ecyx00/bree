import type {
  BreeRequestParams,
  BreeResponseDataFor,
  Id,
  JsonValue,
  WorkspaceMutationResult,
} from "../generated/index.js";

/** Wire command ids are numeric uint64 values. Short ids are CLI-only. */
export type IdRef = Id;
export type Json = JsonValue;
export type CopyMode = BreeRequestParams<"copy">["mode"];
export type IdKind = NonNullable<BreeRequestParams<"ids">["kind"]>;
export type WorkspaceMutation = WorkspaceMutationResult;
export type WorkspacePlacement = BreeResponseDataFor<"create-workspace">;
