// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:messages_builder/generation_options.dart';
import 'package:path/path.dart' as path;

Builder wrapperBuilder(BuilderOptions options) =>
    GenerateWrapperBuilder(options.config);

class GenerateWrapperBuilder implements Builder {
  final Map<String, dynamic> config;
  late final List<String> extensionsForArb;

  GenerateWrapperBuilder(this.config);

  @override
  Map<String, List<String>> get buildExtensions => {
        '.g.dart': ['.flutter.g.dart'],
        '^pubspec.yaml': [],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final generationOptions = await GenerationOptions.fromPubspec(buildStep);
    await BuildStepGenerator(buildStep, generationOptions).build();
  }
}

class BuildStepGenerator {
  final BuildStep buildStep;
  final GenerationOptions generationOptions;

  BuildStepGenerator(this.buildStep, this.generationOptions);

  Future<void> build() async {
    var inputString = await buildStep.readAsString(buildStep.inputId);
    var firstMatch =
        RegExp(r'class ([A-Za-z]*)Messages {').firstMatch(inputString);
    if (firstMatch == null) {
      return;
    }
    final name = '${firstMatch[1]}Messages';
    final delegateName = '_${name}LocalizationsDelegate';
    final localizationsName = '${name}Localizations';
    final emitter = DartEmitter(orderDirectives: true);

    final asset = buildStep.inputId;
    Iterable<Directive> imports = [
      Directive.import('package:flutter/services.dart'),
      Directive.import('package:flutter/widgets.dart'),
      Directive.import(
          'package:flutter_localizations/flutter_localizations.dart'),
      Directive.import('package:messages/package_intl_object.dart'),
      Directive.import(path.basename(asset.path)),
    ];
    Iterable<Spec> classes = [
      Class(
        (cb) => cb
          ..name = localizationsName
          ..fields.addAll(
            [
              Field(
                (fb) => fb
                  ..name = 'localizationsDelegates'
                  ..type = const Reference(
                      'Iterable<LocalizationsDelegate<dynamic>>')
                  ..static = true
                  ..assignment = const Code('''
[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ]'''),
              ),
              Field(
                (fb) => fb
                  ..name = 'delegate'
                  ..type = Reference('LocalizationsDelegate<$name>')
                  ..static = true
                  ..assignment = Code('$delegateName()'),
              ),
            ],
          )
          ..methods.addAll([
            Method(
              (mb) => mb
                ..name = 'supportedLocales'
                ..static = true
                ..type = MethodType.getter
                ..body = Code('''
      return $name.knownLocales.map((e) {
        final split = e.split('_');
        final code = split.length > 1 ? split[1] : null;
        return Locale(split.first, code);
      }).toList();''')
                ..returns = const Reference('List<Locale>'),
            ),
            Method(
              (mb) => mb
                ..name = 'of'
                ..static = true
                ..requiredParameters.add(Parameter(
                  (pb) => pb
                    ..name = 'context'
                    ..type = const Reference('BuildContext'),
                ))
                ..lambda = true
                ..body = Code('Localizations.of<$name>(context, $name)')
                ..returns = Reference('$name?'),
            ),
          ]),
      ),
      Class(
        (cb) => cb
          ..name = delegateName
          ..extend = Reference('LocalizationsDelegate<$name>')
          ..methods.addAll([
            Method(
              (mb) => mb
                ..name = 'isSupported'
                ..annotations.add(const Reference('override'))
                ..lambda = true
                ..body = Code('$name.knownLocales.contains(locale.toString())')
                ..requiredParameters.add(Parameter(
                  (pb) => pb
                    ..name = 'locale'
                    ..type = const Reference('Locale'),
                ))
                ..returns = const Reference('bool'),
            ),
            Method(
              (mb) => mb
                ..name = 'load'
                ..annotations.add(const Reference('override'))
                ..body = const Code('''
await messages.loadLocale(locale.toString());
    return messages;
    ''')
                ..requiredParameters.add(Parameter(
                  (pb) => pb
                    ..name = 'locale'
                    ..type = const Reference('Locale'),
                ))
                ..modifier = MethodModifier.async
                ..returns = Reference('Future<$name>'),
            ),
            Method(
              (mb) => mb
                ..name = 'shouldReload'
                ..annotations.add(const Reference('override'))
                ..lambda = true
                ..body = const Code('false')
                ..requiredParameters.add(Parameter(
                  (pb) => pb
                    ..name = 'old'
                    ..type = Reference('LocalizationsDelegate<$name>'),
                ))
                ..returns = const Reference('bool'),
            )
          ]),
      ),
      Extension(
        (eb) => eb
          ..name = '${localizationsName}Extension'
          ..on = const Reference('BuildContext')
          ..methods.add(Method(
            (mb) => mb
              ..type = MethodType.getter
              ..name = localizationsName.minuscule()
              ..lambda = true
              ..body = const Code('MessagesLocalizations.of(this)')
              ..returns = const Reference('Messages?'),
          )),
      ),
    ];
    var lib = Library((b) => b
      ..comments.add(generationOptions.header)
      ..directives.addAll(imports)
      ..body.addAll([
        ...classes,
        Field((fb) => fb
          ..name = 'messages'
          ..type = Reference(name)
          ..assignment =
              Code('$name(rootBundle.loadString, const OldIntlObject())'))
      ]));
    final source = '${lib.accept(emitter)}';
    final contents = DartFormatter().format(source);
    await buildStep.writeAsString(
        AssetId(asset.package,
            '${asset.path.substring(0, asset.path.length - '.g.dart'.length)}.flutter.g.dart'),
        contents);
  }
}

extension on String {
  String minuscule() {
    return "${this[0].toLowerCase()}${substring(1)}";
  }
}
