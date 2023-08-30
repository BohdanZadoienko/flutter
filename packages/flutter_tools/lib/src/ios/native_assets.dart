// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:native_assets_builder/native_assets_builder.dart'
    show BuildResult;
import 'package:native_assets_cli/native_assets_cli.dart' hide BuildMode;
import 'package:native_assets_cli/native_assets_cli.dart' as native_assets_cli;

import '../base/file_system.dart';
import '../build_info.dart';
import '../globals.dart' as globals;

import '../macos/native_assets.dart';
import '../native_assets.dart'; // Reuse some logic.

/// Dry run the native builds.
///
/// This does not build native assets, it only simulates what the final paths
/// of all assets will be so that this can be embedded in the kernel file and
/// the xcode project.
Future<Uri?> dryRunNativeAssetsiOS({
  required NativeAssetsBuildRunner buildRunner,
  required Uri projectUri,
  required FileSystem fileSystem,
}) async {
  if (await hasNoPackageConfig(buildRunner)) {
    return null;
  }
  if (await isDisabledAndNoNativeAssets(buildRunner)) {
    return null;
  }

  final Uri buildUri_ = buildUri(projectUri, OS.iOS);
  final Iterable<Asset> assetTargetLocations =
      await dryRunNativeAssetsIosInternal(fileSystem, projectUri, buildRunner);
  final Uri nativeAssetsUri =
      await writeNativeAssetsYaml(assetTargetLocations, buildUri_, fileSystem);
  return nativeAssetsUri;
}

Future<Iterable<Asset>> dryRunNativeAssetsIosInternal(
  FileSystem fileSystem,
  Uri projectUri,
  NativeAssetsBuildRunner buildRunner,
) async {
  const OS targetOs = OS.iOS;
  globals.logger.printTrace('Dry running native assets for $targetOs.');
  final List<Asset> nativeAssets = (await buildRunner.dryRun(
    linkModePreference: LinkModePreference.dynamic,
    targetOs: targetOs,
    workingDirectory: projectUri,
    includeParentEnvironment: true,
  ))
      .assets;
  ensureNoLinkModeStatic(nativeAssets);
  globals.logger.printTrace('Dry running native assets for $targetOs done.');
  final Iterable<Asset> assetTargetLocations =
      _assetTargetLocations(nativeAssets).values;
  return assetTargetLocations;
}

/// Builds native assets.
Future<List<Uri>> buildNativeAssetsiOS({
  required NativeAssetsBuildRunner buildRunner,
  required List<DarwinArch> darwinArchs,
  required EnvironmentType environmentType,
  required Uri projectUri,
  required BuildMode buildMode,
  String? codesignIdentity,
  required FileSystem fileSystem,
  required Uri yamlParentDirectory,
}) async {
  if (await hasNoPackageConfig(buildRunner) ||
      await isDisabledAndNoNativeAssets(buildRunner)) {
    await writeNativeAssetsYaml(<Asset>[], yamlParentDirectory, fileSystem);
    return <Uri>[];
  }

  final List<Target> targets = darwinArchs.map(_getNativeTarget).toList();
  final native_assets_cli.BuildMode buildModeCli = getBuildMode(buildMode);

  const OS targetOs = OS.iOS;
  final Uri buildUri_ = buildUri(projectUri, targetOs);
  final IOSSdk iosSdk = _getIosSdk(environmentType);

  globals.logger
      .printTrace('Building native assets for $targets $buildModeCli.');

  final List<Asset> nativeAssets = <Asset>[];
  final Set<Uri> dependencies = <Uri>{};
  for (final Target target in targets) {
    final BuildResult result = await buildRunner.build(
      linkModePreference: LinkModePreference.dynamic,
      target: target,
      targetIOSSdk: iosSdk,
      buildMode: buildModeCli,
      workingDirectory: projectUri,
      includeParentEnvironment: true,
      cCompilerConfig: await buildRunner.cCompilerConfig,
    );
    nativeAssets.addAll(result.assets);
    dependencies.addAll(result.dependencies);
  }
  ensureNoLinkModeStatic(nativeAssets);
  globals.logger.printTrace('Building native assets for $targets done.');
  final Map<AssetPath, List<Asset>> fatAssetTargetLocations =
      _fatAssetTargetLocations(nativeAssets);
  await copyNativeAssets(buildUri_, fatAssetTargetLocations, codesignIdentity,
      buildMode, fileSystem);

  final Map<Asset, Asset> assetTargetLocations =
      _assetTargetLocations(nativeAssets);
  await writeNativeAssetsYaml(
      assetTargetLocations.values, yamlParentDirectory, fileSystem);
  return dependencies.toList();
}

IOSSdk _getIosSdk(EnvironmentType environmentType) {
  switch (environmentType) {
    case EnvironmentType.physical:
      return IOSSdk.iPhoneOs;
    case EnvironmentType.simulator:
      return IOSSdk.iPhoneSimulator;
  }
}

Target _getNativeTarget(DarwinArch darwinArch) {
  switch (darwinArch) {
    case DarwinArch.armv7:
      return Target.iOSArm;
    case DarwinArch.arm64:
      return Target.iOSArm64;
    case DarwinArch.x86_64:
      return Target.iOSX64;
  }
}

Map<AssetPath, List<Asset>> _fatAssetTargetLocations(List<Asset> nativeAssets) {
  final Map<AssetPath, List<Asset>> result = <AssetPath, List<Asset>>{};
  for (final Asset asset in nativeAssets) {
    final AssetPath path = _targetLocationiOS(asset).path;
    result[path] ??= <Asset>[];
    result[path]!.add(asset);
  }
  return result;
}

Map<Asset, Asset> _assetTargetLocations(List<Asset> nativeAssets) =>
    <Asset, Asset>{
      for (final Asset asset in nativeAssets) asset: _targetLocationiOS(asset),
    };

Asset _targetLocationiOS(Asset asset) {
  final AssetPath path = asset.path;
  switch (path) {
    case AssetSystemPath _:
    case AssetInExecutable _:
    case AssetInProcess _:
      return asset;
    case AssetAbsolutePath _:
      final String fileName = path.uri.pathSegments.last;
      return asset.copyWith(path: AssetAbsolutePath(Uri(path: fileName)));
  }
  throw Exception(
      'Unsupported asset path type ${path.runtimeType} in asset $asset');
}
