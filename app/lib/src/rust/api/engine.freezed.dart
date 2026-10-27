// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'engine.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Event {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'Event()';
}


}

/// @nodoc
class $EventCopyWith<$Res>  {
$EventCopyWith(Event _, $Res Function(Event) __);
}


/// Adds pattern-matching-related methods to [Event].
extension EventPatterns on Event {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Event_PeerChanged value)?  peerChanged,TResult Function( Event_PeerGone value)?  peerGone,TResult Function( Event_PairRequest value)?  pairRequest,TResult Function( Event_PairFinished value)?  pairFinished,TResult Function( Event_TransferOffer value)?  transferOffer,TResult Function( Event_TransferStarted value)?  transferStarted,TResult Function( Event_TransferProgress value)?  transferProgress,TResult Function( Event_TransferNote value)?  transferNote,TResult Function( Event_TransferFinished value)?  transferFinished,TResult Function( Event_Log value)?  log,TResult Function( Event_Message value)?  message,TResult Function( Event_Show value)?  show_,TResult Function( Event_Quit value)?  quit,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Event_PeerChanged() when peerChanged != null:
return peerChanged(_that);case Event_PeerGone() when peerGone != null:
return peerGone(_that);case Event_PairRequest() when pairRequest != null:
return pairRequest(_that);case Event_PairFinished() when pairFinished != null:
return pairFinished(_that);case Event_TransferOffer() when transferOffer != null:
return transferOffer(_that);case Event_TransferStarted() when transferStarted != null:
return transferStarted(_that);case Event_TransferProgress() when transferProgress != null:
return transferProgress(_that);case Event_TransferNote() when transferNote != null:
return transferNote(_that);case Event_TransferFinished() when transferFinished != null:
return transferFinished(_that);case Event_Log() when log != null:
return log(_that);case Event_Message() when message != null:
return message(_that);case Event_Show() when show_ != null:
return show_(_that);case Event_Quit() when quit != null:
return quit(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Event_PeerChanged value)  peerChanged,required TResult Function( Event_PeerGone value)  peerGone,required TResult Function( Event_PairRequest value)  pairRequest,required TResult Function( Event_PairFinished value)  pairFinished,required TResult Function( Event_TransferOffer value)  transferOffer,required TResult Function( Event_TransferStarted value)  transferStarted,required TResult Function( Event_TransferProgress value)  transferProgress,required TResult Function( Event_TransferNote value)  transferNote,required TResult Function( Event_TransferFinished value)  transferFinished,required TResult Function( Event_Log value)  log,required TResult Function( Event_Message value)  message,required TResult Function( Event_Show value)  show_,required TResult Function( Event_Quit value)  quit,}){
final _that = this;
switch (_that) {
case Event_PeerChanged():
return peerChanged(_that);case Event_PeerGone():
return peerGone(_that);case Event_PairRequest():
return pairRequest(_that);case Event_PairFinished():
return pairFinished(_that);case Event_TransferOffer():
return transferOffer(_that);case Event_TransferStarted():
return transferStarted(_that);case Event_TransferProgress():
return transferProgress(_that);case Event_TransferNote():
return transferNote(_that);case Event_TransferFinished():
return transferFinished(_that);case Event_Log():
return log(_that);case Event_Message():
return message(_that);case Event_Show():
return show_(_that);case Event_Quit():
return quit(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Event_PeerChanged value)?  peerChanged,TResult? Function( Event_PeerGone value)?  peerGone,TResult? Function( Event_PairRequest value)?  pairRequest,TResult? Function( Event_PairFinished value)?  pairFinished,TResult? Function( Event_TransferOffer value)?  transferOffer,TResult? Function( Event_TransferStarted value)?  transferStarted,TResult? Function( Event_TransferProgress value)?  transferProgress,TResult? Function( Event_TransferNote value)?  transferNote,TResult? Function( Event_TransferFinished value)?  transferFinished,TResult? Function( Event_Log value)?  log,TResult? Function( Event_Message value)?  message,TResult? Function( Event_Show value)?  show_,TResult? Function( Event_Quit value)?  quit,}){
final _that = this;
switch (_that) {
case Event_PeerChanged() when peerChanged != null:
return peerChanged(_that);case Event_PeerGone() when peerGone != null:
return peerGone(_that);case Event_PairRequest() when pairRequest != null:
return pairRequest(_that);case Event_PairFinished() when pairFinished != null:
return pairFinished(_that);case Event_TransferOffer() when transferOffer != null:
return transferOffer(_that);case Event_TransferStarted() when transferStarted != null:
return transferStarted(_that);case Event_TransferProgress() when transferProgress != null:
return transferProgress(_that);case Event_TransferNote() when transferNote != null:
return transferNote(_that);case Event_TransferFinished() when transferFinished != null:
return transferFinished(_that);case Event_Log() when log != null:
return log(_that);case Event_Message() when message != null:
return message(_that);case Event_Show() when show_ != null:
return show_(_that);case Event_Quit() when quit != null:
return quit(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( Peer peer)?  peerChanged,TResult Function( String id)?  peerGone,TResult Function( String peerId,  String name,  String code,  bool incoming)?  pairRequest,TResult Function( String peerId,  String name,  bool ok,  String code,  String message)?  pairFinished,TResult Function( String id,  String peerId,  String peerName,  String name,  BigInt size)?  transferOffer,TResult Function( String id,  String peerId,  String peerName,  String name,  BigInt size,  bool incoming)?  transferStarted,TResult Function( String id,  BigInt done,  BigInt total,  BigInt bytesPerSec)?  transferProgress,TResult Function( String id,  String message)?  transferNote,TResult Function( String id,  bool ok,  String code,  String message,  String path)?  transferFinished,TResult Function( String message)?  log,TResult Function( String peerId,  String kind,  String body)?  message,TResult Function()?  show_,TResult Function()?  quit,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Event_PeerChanged() when peerChanged != null:
return peerChanged(_that.peer);case Event_PeerGone() when peerGone != null:
return peerGone(_that.id);case Event_PairRequest() when pairRequest != null:
return pairRequest(_that.peerId,_that.name,_that.code,_that.incoming);case Event_PairFinished() when pairFinished != null:
return pairFinished(_that.peerId,_that.name,_that.ok,_that.code,_that.message);case Event_TransferOffer() when transferOffer != null:
return transferOffer(_that.id,_that.peerId,_that.peerName,_that.name,_that.size);case Event_TransferStarted() when transferStarted != null:
return transferStarted(_that.id,_that.peerId,_that.peerName,_that.name,_that.size,_that.incoming);case Event_TransferProgress() when transferProgress != null:
return transferProgress(_that.id,_that.done,_that.total,_that.bytesPerSec);case Event_TransferNote() when transferNote != null:
return transferNote(_that.id,_that.message);case Event_TransferFinished() when transferFinished != null:
return transferFinished(_that.id,_that.ok,_that.code,_that.message,_that.path);case Event_Log() when log != null:
return log(_that.message);case Event_Message() when message != null:
return message(_that.peerId,_that.kind,_that.body);case Event_Show() when show_ != null:
return show_();case Event_Quit() when quit != null:
return quit();case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( Peer peer)  peerChanged,required TResult Function( String id)  peerGone,required TResult Function( String peerId,  String name,  String code,  bool incoming)  pairRequest,required TResult Function( String peerId,  String name,  bool ok,  String code,  String message)  pairFinished,required TResult Function( String id,  String peerId,  String peerName,  String name,  BigInt size)  transferOffer,required TResult Function( String id,  String peerId,  String peerName,  String name,  BigInt size,  bool incoming)  transferStarted,required TResult Function( String id,  BigInt done,  BigInt total,  BigInt bytesPerSec)  transferProgress,required TResult Function( String id,  String message)  transferNote,required TResult Function( String id,  bool ok,  String code,  String message,  String path)  transferFinished,required TResult Function( String message)  log,required TResult Function( String peerId,  String kind,  String body)  message,required TResult Function()  show_,required TResult Function()  quit,}) {final _that = this;
switch (_that) {
case Event_PeerChanged():
return peerChanged(_that.peer);case Event_PeerGone():
return peerGone(_that.id);case Event_PairRequest():
return pairRequest(_that.peerId,_that.name,_that.code,_that.incoming);case Event_PairFinished():
return pairFinished(_that.peerId,_that.name,_that.ok,_that.code,_that.message);case Event_TransferOffer():
return transferOffer(_that.id,_that.peerId,_that.peerName,_that.name,_that.size);case Event_TransferStarted():
return transferStarted(_that.id,_that.peerId,_that.peerName,_that.name,_that.size,_that.incoming);case Event_TransferProgress():
return transferProgress(_that.id,_that.done,_that.total,_that.bytesPerSec);case Event_TransferNote():
return transferNote(_that.id,_that.message);case Event_TransferFinished():
return transferFinished(_that.id,_that.ok,_that.code,_that.message,_that.path);case Event_Log():
return log(_that.message);case Event_Message():
return message(_that.peerId,_that.kind,_that.body);case Event_Show():
return show_();case Event_Quit():
return quit();}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( Peer peer)?  peerChanged,TResult? Function( String id)?  peerGone,TResult? Function( String peerId,  String name,  String code,  bool incoming)?  pairRequest,TResult? Function( String peerId,  String name,  bool ok,  String code,  String message)?  pairFinished,TResult? Function( String id,  String peerId,  String peerName,  String name,  BigInt size)?  transferOffer,TResult? Function( String id,  String peerId,  String peerName,  String name,  BigInt size,  bool incoming)?  transferStarted,TResult? Function( String id,  BigInt done,  BigInt total,  BigInt bytesPerSec)?  transferProgress,TResult? Function( String id,  String message)?  transferNote,TResult? Function( String id,  bool ok,  String code,  String message,  String path)?  transferFinished,TResult? Function( String message)?  log,TResult? Function( String peerId,  String kind,  String body)?  message,TResult? Function()?  show_,TResult? Function()?  quit,}) {final _that = this;
switch (_that) {
case Event_PeerChanged() when peerChanged != null:
return peerChanged(_that.peer);case Event_PeerGone() when peerGone != null:
return peerGone(_that.id);case Event_PairRequest() when pairRequest != null:
return pairRequest(_that.peerId,_that.name,_that.code,_that.incoming);case Event_PairFinished() when pairFinished != null:
return pairFinished(_that.peerId,_that.name,_that.ok,_that.code,_that.message);case Event_TransferOffer() when transferOffer != null:
return transferOffer(_that.id,_that.peerId,_that.peerName,_that.name,_that.size);case Event_TransferStarted() when transferStarted != null:
return transferStarted(_that.id,_that.peerId,_that.peerName,_that.name,_that.size,_that.incoming);case Event_TransferProgress() when transferProgress != null:
return transferProgress(_that.id,_that.done,_that.total,_that.bytesPerSec);case Event_TransferNote() when transferNote != null:
return transferNote(_that.id,_that.message);case Event_TransferFinished() when transferFinished != null:
return transferFinished(_that.id,_that.ok,_that.code,_that.message,_that.path);case Event_Log() when log != null:
return log(_that.message);case Event_Message() when message != null:
return message(_that.peerId,_that.kind,_that.body);case Event_Show() when show_ != null:
return show_();case Event_Quit() when quit != null:
return quit();case _:
  return null;

}
}

}

/// @nodoc


class Event_PeerChanged extends Event {
  const Event_PeerChanged({required this.peer}): super._();
  

 final  Peer peer;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_PeerChangedCopyWith<Event_PeerChanged> get copyWith => _$Event_PeerChangedCopyWithImpl<Event_PeerChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_PeerChanged&&(identical(other.peer, peer) || other.peer == peer));
}


@override
int get hashCode {
    return Object.hash(runtimeType,peer);
}

@override
String toString() {
    return 'Event.peerChanged(peer: $peer)';
}


}

/// @nodoc
abstract mixin class $Event_PeerChangedCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_PeerChangedCopyWith(Event_PeerChanged value, $Res Function(Event_PeerChanged) _then) = _$Event_PeerChangedCopyWithImpl;
@useResult
$Res call({
 Peer peer
});




}
/// @nodoc
class _$Event_PeerChangedCopyWithImpl<$Res>
    implements $Event_PeerChangedCopyWith<$Res> {
  _$Event_PeerChangedCopyWithImpl(this._self, this._then);

  final Event_PeerChanged _self;
  final $Res Function(Event_PeerChanged) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peer = null,}) {
  return _then(Event_PeerChanged(
peer: null == peer ? _self.peer : peer // ignore: cast_nullable_to_non_nullable
as Peer,
  ));
}


}

/// @nodoc


class Event_PeerGone extends Event {
  const Event_PeerGone({required this.id}): super._();
  

 final  String id;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_PeerGoneCopyWith<Event_PeerGone> get copyWith => _$Event_PeerGoneCopyWithImpl<Event_PeerGone>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_PeerGone&&(identical(other.id, id) || other.id == id));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id);
}

@override
String toString() {
    return 'Event.peerGone(id: $id)';
}


}

/// @nodoc
abstract mixin class $Event_PeerGoneCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_PeerGoneCopyWith(Event_PeerGone value, $Res Function(Event_PeerGone) _then) = _$Event_PeerGoneCopyWithImpl;
@useResult
$Res call({
 String id
});




}
/// @nodoc
class _$Event_PeerGoneCopyWithImpl<$Res>
    implements $Event_PeerGoneCopyWith<$Res> {
  _$Event_PeerGoneCopyWithImpl(this._self, this._then);

  final Event_PeerGone _self;
  final $Res Function(Event_PeerGone) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,}) {
  return _then(Event_PeerGone(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Event_PairRequest extends Event {
  const Event_PairRequest({required this.peerId, required this.name, required this.code, required this.incoming}): super._();
  

 final  String peerId;
 final  String name;
 final  String code;
 final  bool incoming;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_PairRequestCopyWith<Event_PairRequest> get copyWith => _$Event_PairRequestCopyWithImpl<Event_PairRequest>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_PairRequest&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.name, name) || other.name == name)&&(identical(other.code, code) || other.code == code)&&(identical(other.incoming, incoming) || other.incoming == incoming));
}


@override
int get hashCode {
    return Object.hash(runtimeType,peerId,name,code,incoming);
}

@override
String toString() {
    return 'Event.pairRequest(peerId: $peerId, name: $name, code: $code, incoming: $incoming)';
}


}

/// @nodoc
abstract mixin class $Event_PairRequestCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_PairRequestCopyWith(Event_PairRequest value, $Res Function(Event_PairRequest) _then) = _$Event_PairRequestCopyWithImpl;
@useResult
$Res call({
 String peerId, String name, String code, bool incoming
});




}
/// @nodoc
class _$Event_PairRequestCopyWithImpl<$Res>
    implements $Event_PairRequestCopyWith<$Res> {
  _$Event_PairRequestCopyWithImpl(this._self, this._then);

  final Event_PairRequest _self;
  final $Res Function(Event_PairRequest) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? name = null,Object? code = null,Object? incoming = null,}) {
  return _then(Event_PairRequest(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,incoming: null == incoming ? _self.incoming : incoming // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class Event_PairFinished extends Event {
  const Event_PairFinished({required this.peerId, required this.name, required this.ok, required this.code, required this.message}): super._();
  

 final  String peerId;
 final  String name;
 final  bool ok;
 final  String code;
 final  String message;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_PairFinishedCopyWith<Event_PairFinished> get copyWith => _$Event_PairFinishedCopyWithImpl<Event_PairFinished>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_PairFinished&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.name, name) || other.name == name)&&(identical(other.ok, ok) || other.ok == ok)&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode {
    return Object.hash(runtimeType,peerId,name,ok,code,message);
}

@override
String toString() {
    return 'Event.pairFinished(peerId: $peerId, name: $name, ok: $ok, code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class $Event_PairFinishedCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_PairFinishedCopyWith(Event_PairFinished value, $Res Function(Event_PairFinished) _then) = _$Event_PairFinishedCopyWithImpl;
@useResult
$Res call({
 String peerId, String name, bool ok, String code, String message
});




}
/// @nodoc
class _$Event_PairFinishedCopyWithImpl<$Res>
    implements $Event_PairFinishedCopyWith<$Res> {
  _$Event_PairFinishedCopyWithImpl(this._self, this._then);

  final Event_PairFinished _self;
  final $Res Function(Event_PairFinished) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? name = null,Object? ok = null,Object? code = null,Object? message = null,}) {
  return _then(Event_PairFinished(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,ok: null == ok ? _self.ok : ok // ignore: cast_nullable_to_non_nullable
as bool,code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Event_TransferOffer extends Event {
  const Event_TransferOffer({required this.id, required this.peerId, required this.peerName, required this.name, required this.size}): super._();
  

 final  String id;
 final  String peerId;
 final  String peerName;
 final  String name;
 final  BigInt size;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_TransferOfferCopyWith<Event_TransferOffer> get copyWith => _$Event_TransferOfferCopyWithImpl<Event_TransferOffer>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_TransferOffer&&(identical(other.id, id) || other.id == id)&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.peerName, peerName) || other.peerName == peerName)&&(identical(other.name, name) || other.name == name)&&(identical(other.size, size) || other.size == size));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id,peerId,peerName,name,size);
}

@override
String toString() {
    return 'Event.transferOffer(id: $id, peerId: $peerId, peerName: $peerName, name: $name, size: $size)';
}


}

/// @nodoc
abstract mixin class $Event_TransferOfferCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_TransferOfferCopyWith(Event_TransferOffer value, $Res Function(Event_TransferOffer) _then) = _$Event_TransferOfferCopyWithImpl;
@useResult
$Res call({
 String id, String peerId, String peerName, String name, BigInt size
});




}
/// @nodoc
class _$Event_TransferOfferCopyWithImpl<$Res>
    implements $Event_TransferOfferCopyWith<$Res> {
  _$Event_TransferOfferCopyWithImpl(this._self, this._then);

  final Event_TransferOffer _self;
  final $Res Function(Event_TransferOffer) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? peerId = null,Object? peerName = null,Object? name = null,Object? size = null,}) {
  return _then(Event_TransferOffer(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,peerName: null == peerName ? _self.peerName : peerName // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,size: null == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class Event_TransferStarted extends Event {
  const Event_TransferStarted({required this.id, required this.peerId, required this.peerName, required this.name, required this.size, required this.incoming}): super._();
  

 final  String id;
 final  String peerId;
 final  String peerName;
 final  String name;
 final  BigInt size;
 final  bool incoming;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_TransferStartedCopyWith<Event_TransferStarted> get copyWith => _$Event_TransferStartedCopyWithImpl<Event_TransferStarted>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_TransferStarted&&(identical(other.id, id) || other.id == id)&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.peerName, peerName) || other.peerName == peerName)&&(identical(other.name, name) || other.name == name)&&(identical(other.size, size) || other.size == size)&&(identical(other.incoming, incoming) || other.incoming == incoming));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id,peerId,peerName,name,size,incoming);
}

@override
String toString() {
    return 'Event.transferStarted(id: $id, peerId: $peerId, peerName: $peerName, name: $name, size: $size, incoming: $incoming)';
}


}

/// @nodoc
abstract mixin class $Event_TransferStartedCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_TransferStartedCopyWith(Event_TransferStarted value, $Res Function(Event_TransferStarted) _then) = _$Event_TransferStartedCopyWithImpl;
@useResult
$Res call({
 String id, String peerId, String peerName, String name, BigInt size, bool incoming
});




}
/// @nodoc
class _$Event_TransferStartedCopyWithImpl<$Res>
    implements $Event_TransferStartedCopyWith<$Res> {
  _$Event_TransferStartedCopyWithImpl(this._self, this._then);

  final Event_TransferStarted _self;
  final $Res Function(Event_TransferStarted) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? peerId = null,Object? peerName = null,Object? name = null,Object? size = null,Object? incoming = null,}) {
  return _then(Event_TransferStarted(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,peerName: null == peerName ? _self.peerName : peerName // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,size: null == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as BigInt,incoming: null == incoming ? _self.incoming : incoming // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class Event_TransferProgress extends Event {
  const Event_TransferProgress({required this.id, required this.done, required this.total, required this.bytesPerSec}): super._();
  

 final  String id;
 final  BigInt done;
 final  BigInt total;
 final  BigInt bytesPerSec;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_TransferProgressCopyWith<Event_TransferProgress> get copyWith => _$Event_TransferProgressCopyWithImpl<Event_TransferProgress>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_TransferProgress&&(identical(other.id, id) || other.id == id)&&(identical(other.done, done) || other.done == done)&&(identical(other.total, total) || other.total == total)&&(identical(other.bytesPerSec, bytesPerSec) || other.bytesPerSec == bytesPerSec));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id,done,total,bytesPerSec);
}

@override
String toString() {
    return 'Event.transferProgress(id: $id, done: $done, total: $total, bytesPerSec: $bytesPerSec)';
}


}

/// @nodoc
abstract mixin class $Event_TransferProgressCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_TransferProgressCopyWith(Event_TransferProgress value, $Res Function(Event_TransferProgress) _then) = _$Event_TransferProgressCopyWithImpl;
@useResult
$Res call({
 String id, BigInt done, BigInt total, BigInt bytesPerSec
});




}
/// @nodoc
class _$Event_TransferProgressCopyWithImpl<$Res>
    implements $Event_TransferProgressCopyWith<$Res> {
  _$Event_TransferProgressCopyWithImpl(this._self, this._then);

  final Event_TransferProgress _self;
  final $Res Function(Event_TransferProgress) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? done = null,Object? total = null,Object? bytesPerSec = null,}) {
  return _then(Event_TransferProgress(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,done: null == done ? _self.done : done // ignore: cast_nullable_to_non_nullable
as BigInt,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt,bytesPerSec: null == bytesPerSec ? _self.bytesPerSec : bytesPerSec // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class Event_TransferNote extends Event {
  const Event_TransferNote({required this.id, required this.message}): super._();
  

 final  String id;
 final  String message;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_TransferNoteCopyWith<Event_TransferNote> get copyWith => _$Event_TransferNoteCopyWithImpl<Event_TransferNote>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_TransferNote&&(identical(other.id, id) || other.id == id)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id,message);
}

@override
String toString() {
    return 'Event.transferNote(id: $id, message: $message)';
}


}

/// @nodoc
abstract mixin class $Event_TransferNoteCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_TransferNoteCopyWith(Event_TransferNote value, $Res Function(Event_TransferNote) _then) = _$Event_TransferNoteCopyWithImpl;
@useResult
$Res call({
 String id, String message
});




}
/// @nodoc
class _$Event_TransferNoteCopyWithImpl<$Res>
    implements $Event_TransferNoteCopyWith<$Res> {
  _$Event_TransferNoteCopyWithImpl(this._self, this._then);

  final Event_TransferNote _self;
  final $Res Function(Event_TransferNote) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? message = null,}) {
  return _then(Event_TransferNote(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Event_TransferFinished extends Event {
  const Event_TransferFinished({required this.id, required this.ok, required this.code, required this.message, required this.path}): super._();
  

 final  String id;
 final  bool ok;
 final  String code;
 final  String message;
 final  String path;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_TransferFinishedCopyWith<Event_TransferFinished> get copyWith => _$Event_TransferFinishedCopyWithImpl<Event_TransferFinished>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_TransferFinished&&(identical(other.id, id) || other.id == id)&&(identical(other.ok, ok) || other.ok == ok)&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message)&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id,ok,code,message,path);
}

@override
String toString() {
    return 'Event.transferFinished(id: $id, ok: $ok, code: $code, message: $message, path: $path)';
}


}

/// @nodoc
abstract mixin class $Event_TransferFinishedCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_TransferFinishedCopyWith(Event_TransferFinished value, $Res Function(Event_TransferFinished) _then) = _$Event_TransferFinishedCopyWithImpl;
@useResult
$Res call({
 String id, bool ok, String code, String message, String path
});




}
/// @nodoc
class _$Event_TransferFinishedCopyWithImpl<$Res>
    implements $Event_TransferFinishedCopyWith<$Res> {
  _$Event_TransferFinishedCopyWithImpl(this._self, this._then);

  final Event_TransferFinished _self;
  final $Res Function(Event_TransferFinished) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? ok = null,Object? code = null,Object? message = null,Object? path = null,}) {
  return _then(Event_TransferFinished(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,ok: null == ok ? _self.ok : ok // ignore: cast_nullable_to_non_nullable
as bool,code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Event_Log extends Event {
  const Event_Log({required this.message}): super._();
  

 final  String message;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_LogCopyWith<Event_Log> get copyWith => _$Event_LogCopyWithImpl<Event_Log>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_Log&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message);
}

@override
String toString() {
    return 'Event.log(message: $message)';
}


}

/// @nodoc
abstract mixin class $Event_LogCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_LogCopyWith(Event_Log value, $Res Function(Event_Log) _then) = _$Event_LogCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$Event_LogCopyWithImpl<$Res>
    implements $Event_LogCopyWith<$Res> {
  _$Event_LogCopyWithImpl(this._self, this._then);

  final Event_Log _self;
  final $Res Function(Event_Log) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(Event_Log(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Event_Message extends Event {
  const Event_Message({required this.peerId, required this.kind, required this.body}): super._();
  

 final  String peerId;
 final  String kind;
 final  String body;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Event_MessageCopyWith<Event_Message> get copyWith => _$Event_MessageCopyWithImpl<Event_Message>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_Message&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.body, body) || other.body == body));
}


@override
int get hashCode {
    return Object.hash(runtimeType,peerId,kind,body);
}

@override
String toString() {
    return 'Event.message(peerId: $peerId, kind: $kind, body: $body)';
}


}

/// @nodoc
abstract mixin class $Event_MessageCopyWith<$Res> implements $EventCopyWith<$Res> {
  factory $Event_MessageCopyWith(Event_Message value, $Res Function(Event_Message) _then) = _$Event_MessageCopyWithImpl;
@useResult
$Res call({
 String peerId, String kind, String body
});




}
/// @nodoc
class _$Event_MessageCopyWithImpl<$Res>
    implements $Event_MessageCopyWith<$Res> {
  _$Event_MessageCopyWithImpl(this._self, this._then);

  final Event_Message _self;
  final $Res Function(Event_Message) _then;

/// Create a copy of Event
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? kind = null,Object? body = null,}) {
  return _then(Event_Message(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,body: null == body ? _self.body : body // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Event_Show extends Event {
  const Event_Show(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_Show);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'Event.show_()';
}


}




/// @nodoc


class Event_Quit extends Event {
  const Event_Quit(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Event_Quit);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'Event.quit()';
}


}




// dart format on
