# Mesa Downstream Synchronization

`Khronos_AppleICDs` carries two Mesa downstream lines in the
[`AO46Mesa`](https://github.com/Anonymous137-sudo/AO46Mesa) fork:

| Product | Parent path | Protected fork branch |
| --- | --- | --- |
| AO46 OpenGL | `OpenGL_4.6(Core Profile)/mesa` | `ao46-opengl` |
| AVK143 Vulkan | `Vulkan_API_SDK_1.4.354/mesa` | `avk143-vulkan-mainline` |

They intentionally remain separate. OpenGL carries Mesa state-tracker,
KosmicKrisp compiler, Asahi research, and AO46 registration work. Vulkan
carries the KosmicKrisp ICD and AVK capability/CTS work. Updating one product
must not silently move the other product's gitlink.

## Safety Model

The updater never rebases, resets, or overwrites the developer's live
submodule checkout. It clones the protected branch into a temporary directory,
fetches Mesa `main`, exports every downstream commit since the merge base as a
binary/full-index patch series, and creates a merge candidate.

A candidate is valid only if:

1. the previous downstream head is an ancestor of the candidate;
2. the selected Mesa upstream head is an ancestor of the candidate;
3. the merged range passes `git diff --check`;
4. the product build and regression suite pass in the candidate branch;
5. a maintainer reviews and merges the fork pull request.

Conflicts fail closed. The workflow publishes the conflict report and patch
backup but changes neither the protected fork branch nor the parent pointer.
This makes disappearance of AO46, Asahi, KosmicKrisp, or Metal Gallium work an
explicit invariant failure rather than a possible updater side effect.

## Local Use

Check whether a downstream is behind:

```sh
./scripts/mesa-downstream-sync.sh check opengl
./scripts/mesa-downstream-sync.sh check vulkan
```

Prepare a local candidate and preservation report:

```sh
./scripts/mesa-downstream-sync.sh prepare opengl
./scripts/mesa-downstream-sync.sh prepare vulkan
```

Passing `--push` publishes only the generated automation branch. It never
updates the protected branch directly.

After reviewed fork pull requests are merged, refresh the parent gitlinks:

```sh
./scripts/mesa-refresh-pointers.sh
```

The pointer refresh stages gitlinks only to the protected branch heads. Review,
build, and commit those staged pointer changes in the parent repository.

## GitHub Automation

`.github/workflows/mesa-upstream-sync.yml` runs weekly and can be dispatched
manually. It requires an `AO46_MESA_TOKEN` repository secret with permission to
push branches and open pull requests in `Anonymous137-sudo/AO46Mesa`.

The workflow creates candidate pull requests; it does not auto-merge them.
Parent gitlink refreshes are submitted as separate pull requests after a
protected fork branch changes. This separation prevents an untested upstream
merge from entering a driver release merely because a scheduled job ran.
