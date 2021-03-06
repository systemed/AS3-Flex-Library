/*
Copyright 2009  Mindspace LLC, Thomas Burleson

Licensed under the Apache License, Version 2.0 (the "License"); 
you may not use this file except in compliance with the License. Y
ou may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0 

Unless required by applicable law or agreed to in writing, s
oftware distributed under the License is distributed on an "AS IS" BASIS, 
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
See the License for the specific language governing permissions and limitations under the License

Author: Thomas Burleson, Principal Architect
thomas burleson at g mail dot com

@ignore
*/
package org.babelfx.injectors
{
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.IEventDispatcher;
	import flash.utils.Dictionary;
	import flash.utils.getQualifiedClassName;
	
	import mx.collections.ArrayCollection;
	import mx.core.IMXMLObject;
	import mx.core.UIComponent;
	import mx.events.FlexEvent;
	import mx.events.PropertyChangeEvent;
	import mx.events.StateChangeEvent;
	import mx.logging.ILogger;
	import mx.resources.IResourceManager;
	import mx.resources.ResourceManager;
	import mx.styles.IStyleClient;
	import mx.utils.StringUtil;
	
	import org.babelfx.events.LocaleMapEvent;
	import org.babelfx.maps.LocaleMap;
	import org.babelfx.proxys.ResourceSetter;
	import org.babelfx.utils.InjectorUtils;
	import org.babelfx.utils.debug.LocaleLogger;
	
	/**
	 * Sample MXML Usage.
	 * @code
	 * 
	 *  &lt;ResourceInjector id="rbProxy" bundle="registration"&gt;
	 *	 	&lt;mx:Array&gt;
	 *          &lt;ResourceSetter 	target="" property="" key="" bundle="" parameters=""  /&gt;
	 *	 		&lt;mx:Object 		target="" property="" key="" bundle="" /&gt;
	 *	 	&lt;/mx:Array&gt;
	 *	 &lt;/ResourceInjector&gt;
	 *  
	 * @author thomasburleson
	 * 
	 */
	[DefaultProperty("registry")]
	[Event(name="change",type="flash.events.Event")]
	[Event(name="localeChange", type="flash.events.Event")]
	
	[ExcludeClass]
	
	public class AbstractInjector extends EventDispatcher implements IMXMLObject {
		
		public var log		   : ILogger= LocaleLogger.getLogger(this);
		
		public var id         : String = "";
		public var bundleName : String = ""; 
		
		[ArrayElementType( "Object" )]
		/**
		 * Add one or more items to the ResourceInjector registry.
		 * ([ArrayElementType( "Object" )] metadata is to avoid http://j.mp/FB-12316)
		 * 
		 */
		protected function get registry():Object {
			return _registry;
		}
		public function set registry(target:Object):void {
			if (_initialized != true)  _cached = target;
			else					   buildRegistry(target);
		}
		
		
		// *********************************************************************************
		//  Public Constructor 
		// *********************************************************************************
		
		/**
		 * Public constructor 
		 *  
		 * @param bundleName
		 * 
		 */
		public function AbstractInjector( bundleName:String="", localeManager:IResourceManager=null)  
		{  
			this.bundleName      = bundleName;
			
			_resourceManager = !localeManager ? ResourceManager.getInstance() : localeManager;
			_resourceManager.addEventListener(Event.CHANGE, onLocaleChange, false, 0, true);
		}  
		
		// *********************************************************************************
		//  IMXMLObject Interface 
		// *********************************************************************************
		
		/**
		 * Method is auto-invoked during MXML initialization. Note: if a ResourceInjector instance
		 * was programmatically instantiated (not as a tag), then this method is never called.
		 * 
		 * @param document	Owner for this tag instance
		 * @param id       Reference for this tag instances
		 * 
		 */
		public function initialized(document:Object, id:String):void {
			this.id = id;
			_owner = document as IEventDispatcher;
			
			// Make sure the owner has finished creating all children to insure that calls to the 'function set registry()' 
			// is performed with values that are initialized properly in the owner.
			if (document is LocaleMap) {
				_owner.addEventListener(LocaleMapEvent.TARGET_READY,onBuildRegistry,false,0,true);
			} else if (document is UIComponent && !UIComponent(_owner).initialized) {
				_owner.addEventListener(FlexEvent.CREATION_COMPLETE,onBuildRegistry,false,0,true);
			} 
			
			// Always inject immediately... so non-databinding models are injected and 
			// are ready for use in views!
			onBuildRegistry();
		} 
		
		// *********************************************************************************
		//  Public Methods
		// *********************************************************************************
		
		/**
		 * Programmatic support to trigger locale updates
		 * Useful when the ResourceInjector is programmatically instantiated with new ResourceInjector();
		 *  
		 * @return  
		 * 
		 */
		public function updateNow():void {
			onBuildRegistry();
			assignResourceValues();
		}
		
		
		
		/**
		 * 
		 * @param target
		 * 
		 */
		public function release(target:Object=null):void {
			
			if (target != null) {
				if ((target is String) && _registry[target])  {
					// release item by ID key; each ID key is unique
					delete _registry[target];	
				}
				else if (target is UIComponent) {
					// release all items by reference to target instance...
					// scan all items in registry
					for (var key:String in _registry) {
						var it : ResourceSetter = _registry[key] as ResourceSetter;
						
						if (!it && (it.target == target)) {
							// remove release of change listener
							// remove listener to stateChanges...
							
							(it as IEventDispatcher).removeEventListener(PropertyChangeEvent.PROPERTY_CHANGE,onRegistrationChanges);
							if ((it.state != "") && !it.trigger) {
								(it.trigger as IEventDispatcher).removeEventListener(StateChangeEvent.CURRENT_STATE_CHANGE,onTargetStateChange);
							}
							
							delete _registry[key];
						} 
					}
				} else if (target is ResourceSetter) {
					self::removeItem(target as ResourceSetter);
				}
			}
			else if (target == null) {
				// Completely disconnect for UI and ResourceManager;
				_registry = new Dictionary(true);
				_resourceManager.removeEventListener(Event.CHANGE, onLocaleChange);
			}
		}
		
		/**
		 *  Method to add generic, init object instances to the Registry.
		 *  Objects are first translated to ResourceMap instances.
		 * 
		 * @param src Initialization object (associative array)
		 * @return ResourceMap that was added to the registry
		 * 
		 */
		private function addItem(src:Object):ResourceSetter {
			if (src == null) return null;
			
			var results     :ResourceSetter= null;
			
			var target		:Object 	= keyValue("target",null);
			var state       :String     = keyValue("state","");
			var property	:String 	= keyValue("property",null)  ? keyValue("property") 	: keyValue("uiKey");
			var key			:String		= keyValue("key",null) 	     ? keyValue("key")			: keyValue("resourceKey")
			var type		:String		= keyValue("type",null) 	 ? keyValue("type")			: keyValue("uiType","string");
			var bundle		:String		= keyValue("bundle",null)    ? keyValue("bundle") 	    : keyValue("bundleName");
			var parameters	:Array		= keyValue("parameters",null);
			
			if ((target != null) && (property != "") && (key != "")) {
				
				if (_registry[key] == undefined) {
					if (bundle == "") bundle = this.bundleName;
					
					results = new ResourceSetter(target,key,property,state,type,parameters,bundle);
					_registry[key] = results;
				}
				assignResourceValues();
			}
			
			function keyValue(key:String,defaultVal:*=""):* {
				var result : * = defaultVal;
				if (src && src.hasOwnProperty(key)) {
					result = src[key];
				}
				return result;
			}
			
			return results;
		}
		
		/**
		 * Internal Method override to add ResourceSetter items to registry
		 *  
		 * @param map ResourceSetter instance
		 * @return Reference to ResourceSetter instance.
		 * 
		 */
		self function addItem(map:ResourceSetter):ResourceSetter {
			if (map != null) {
				
				if (findItemByMap(map) == null) {
					
					if (map.bundleName == "") map.bundleName = this.bundleName;
					if (map is ResourceSetter) IEventDispatcher(map).addEventListener(PropertyChangeEvent.PROPERTY_CHANGE,onRegistrationChanges,false,0,true);
					
					if (map.key != "") _registry[map.key] = map;
				}
				
				assignResourceValuesTo(map);
			}
			
			return map; 
		}
		
		self function removeItem(map:ResourceSetter):void {
			if (map != null ) {
				if (map is ResourceSetter) IEventDispatcher(map).removeEventListener(PropertyChangeEvent.PROPERTY_CHANGE,onRegistrationChanges);
				if (findItemByMap(map) == true) delete _registry[map.key];
			}
		}
		
		// *********************************************************************************
		//  Proxy Methods
		// *********************************************************************************
		
		
		/**
		 * Proxy method to provide programmatic access to ResourceManager::getString() functionality
		 * 
		 * @param key			Name/ID key for name/value pair in the specified resource bundle 
		 * @param parameters   Optional parameters to be used for parameterized results
		 * @param bundle		Optional bundlename that overrides the default specified in ResourceInjector constructor
		 * 
		 * @return				String lookup results for the specified locale/bundle 
		 * 
		 */
		public function getString( key:String, parameters:Array=null, bundle:String="" ):String {  
			return _resourceManager.getString( (bundle=="") ? bundleName : bundle, key, parameters );  
		}  
		
		
		// *********************************************************************************
		//  Private Event Handlers
		// *********************************************************************************
		
		/**
		 * The locale has changed, so update the properties of all items registered for any bundle 
		 * @param event ResourceEvent.Change
		 * 
		 */
		protected function onLocaleChange(event:Event=null):void {
			assignResourceValues();
			dispatchEvent(new Event("localeChange"));
		}
		
		
		/**
		 * The Owner to this tag (
		 * @param event
		 * 
		 */
		protected function onBuildRegistry(event:Event=null):void {
			if (event && (event is LocaleMapEvent)) _owner.removeEventListener(LocaleMapEvent.TARGET_READY,onBuildRegistry);
			if (event && (event is FlexEvent)) 		_owner.removeEventListener(FlexEvent.CREATION_COMPLETE,onBuildRegistry);
			
			if (_cached != null) {
				buildRegistry(_cached);
				_cached      = null;
				
			}
		}
		
		/**
		 * The target, trigger, or parameterized values for a registry item has changed... 
		 * therefore we must scan the associated bundle and update the target with 
		 * current localization [and parameterized text if specified]
		 *  
		 * @param event
		 */
		protected function onRegistrationChanges(event:PropertyChangeEvent):void {
			var rProxy : ResourceSetter = event.target as ResourceSetter;
			
			self::addItem(rProxy);
			dispatchEvent(new Event(Event.CHANGE));
		}
		
		
		/**
		 * When state change occurs the "trigger" reference of the ResourceProxies then triggers 
		 * StateChange updates for matching ResourceMaps...
		 *  
		 * @param event StateChangeEvent.CURRENT_STATE_CHANGE	
		 * 
		 */
		protected function onTargetStateChange(event:StateChangeEvent):void {
			log.debug("onTargetStateChange({0})",event.newState);
			
			//assignResourceValues(event.newState);
		}
		
		
		
		// *********************************************************************************
		//  Private Methods
		// *********************************************************************************
		
		/**
		 * Build a registry from the target instances. 
		 *  
		 * @param target  
		 * 
		 */
		protected function buildRegistry(target:Object):void {
			//log.debug("buildRegistry()");
			
			var items : Array = [];
			
			if (target is Array) 				items = target as Array;
			else if (target is ArrayCollection)	items = ArrayCollection(target).source;
			else if (target  is Object)         items = [target];
			
			for (var j:int=0; j<items.length; j++) {
				var it:Object = items[j];
				
				if (it is ResourceSetter) 	self::addItem(it as ResourceSetter);		// Add typed item
				else                     	addItem(it);							// Add generic object
			}
			
			_initialized = true;
		}
		
		/**
		 * The locale has changed, so update all registered targets with the resource key value for their associated bundle
		 *  
		 * @param forceAssignments Trigger updates even if the ResourceInjector has not instantiated as a MXML tag.
		 * @private 
		 */
		protected function assignResourceValues(viewState:String=""):Boolean {
			if (_initialized != true) 	return false;
			
			var announceChanges : Boolean = false;
			
			for (var key:Object in _registry) {
				var map : ResourceSetter = (_registry[key] as ResourceSetter);
				if ((map.state == viewState) || (viewState == "")) {
					assignResourceValuesTo(map);
					announceChanges = true;
				}
			}
			
			if (announceChanges == true) {
				log.debug("announcing Event.CHANGE");
				dispatchEvent(new Event(Event.CHANGE));
			}
			
			return announceChanges;
		}	 
		
		
		/**
		 * Core method that injections the current locale value into the property of the
		 * specified target. This method also confirms state values [if specified].
		 * 
		 * @param ui
		 * 
		 */
		protected function assignResourceValuesTo(map:ResourceSetter):void {
			if (!map || !map.target || (map.target is Class)) return;
			
			var target:Object = map.target;
			
			if (map.bundleName != "") {
				var ui       : Object = resolveEndPoint(map);
				var property : String = resolveProperty(map);
				
				if (isResolvedValid(ui,property) != true) {
					
					logError(map,ERROR_UNKNOWN_PROPERTY);
					
				} else if (isValidTargetState(map) == true) {
					
					// _counter ++;
					//log.debug("l10nInjection ({0}): {1} -> {2}",_counter, map.key,map.property));
					
					switch(map.type) {
						
						case "string"	: assignKeyValue(_resourceManager.getString(map.bundleName,map.key,map.parameters));				break;
						case "boolean"	: assignKeyValue(_resourceManager.getBoolean(map.bundleName,map.key));					  	break;
						case "uint"     : assignKeyValue(_resourceManager.getUint(map.bundleName,map.key));						 		break;
						case "int"      : assignKeyValue(_resourceManager.getInt(map.bundleName,map.key));							  break;
						case "object"   : assignKeyValue(_resourceManager.getObject(map.bundleName,map.key));						  break;
						case "array"    : assignKeyValue(_resourceManager.getStringArray(map.bundleName,map.key));					  break;
						case "class"    : assignKeyValue(_resourceManager.getClass(map.bundleName,map.key));								break;
						
						default         : logError(map,ERROR_UNKNOWN_DATATYPE);															 break;
					}
				}
			} else {
				logError(map,ERROR_UNKNOWN_BUNDLE);
			}
			
			function assignKeyValue(val:*):void {
				if (val == null) {
				  logError(map, ERROR_KEY_VALUE_MISSING);
				} else {
				  
				  if (ui.hasOwnProperty(property) == true) 	{
					  // The target property could be a function...
					  try {
					  	var accessor : Function = ui[property] as Function;
					  } catch (e:Error) { 
						  // do nothing...
					  }
					  
					  if (accessor != null)  accessor.apply(ui,[val]);
					  else					 ui[property] = val;
					  
				  }
				  else if (ui is IStyleClient) {
					  // If not a property or a setter, then check if a style should be applied
					  (ui as IStyleClient).setStyle(property,val);
				  }
				  
				  log.debug("inject '{0}' into '{1}' from resource {2}::{3}",val,map.property,map.bundleName,map.key);
				}
			}
			
			
		}
		
		/**
		 * Reverse lookup method to see if ResourceMap is already in the registry
		 *  
		 * @param map ResourceMap instance to use in reverse lookup
		 * @return Target object used as key for the specified ResourceMap
		 * 
		 */
		private function findItemByMap(map:ResourceSetter):Object {
			var results : Object = null;
			
			for (var key:Object in _registry) {
				if (_registry[key] == map) {
					
					if (key != map.key) {
						// The target changed (see ResourceSetter); so clear registry
						delete _registry[key];
						key = null;
					}
					
					results = key;
					break;
				}
			}
			
			return results;
		}
		
		private function isResolvedValid(ui:Object, property:String):Boolean {
			var results : Boolean = (ui != null) 		&&
				(property != "") 	&&
				(ui.hasOwnProperty(property) == true);
			
			// If the ui does not have a standard property, then is
			// the property actually a styling key?
			
			if ((results!=true) && (ui is UIComponent)) {
				// Is the property a "style" key?
				if( UIComponent(ui).getStyle(property) != null) {
					results = true;
				}
			} 
			
			return results; 	  
		}
		
		private function isValidTargetState(map:ResourceSetter):Boolean {
			var results 	 : Boolean = true;
			var desiredState: String  = map.state;
			
			function listenStateChanges(map:ResourceSetter):UIComponent {
				// If trigger is NOT specified, use parent of target
				var ui  : UIComponent  = (map.trigger ? map.trigger : scanForTrigger(map.target)) as UIComponent;
				if (ui != null) {
					
					if (ui.willTrigger(StateChangeEvent.CURRENT_STATE_CHANGE) != true) {
						ui.addEventListener(StateChangeEvent.CURRENT_STATE_CHANGE, onTargetStateChange,false,0,true);
						
						var clazzName : String = getQualifiedClassName(ui); 
						log.debug("listenStateChanges() for trigger='{0}',name='{1}'",clazzName,ui.name);
					}
				}
				return ui;
			}
			
			// Scan up the target -> parent hierarchy for any 
			function scanForTrigger(src:Object):UIComponent {
				var results :UIComponent = null;
				if (src && src is UIComponent) {
					var ui : UIComponent = src as UIComponent;
					
					results = (ui.states.length > 0) ? ui : scanForTrigger(ui.parent);
				}
				
				return results;
			}
			
			
			if (desiredState!="") {
				var ui : UIComponent = listenStateChanges(map);
				results = ui ? (ui.currentState == desiredState) : false;
			}
			
			return results;
		}
		
		
		/**
		 * Determine the object endpoint based on target and property values
		 * e.g.    target="{healthCare}"  property="pnlQualification.txtSummary.text"
		 *         object endpoint is healthCare.pnlQualification.txtSummary === txtSummary
		 * 
		 * @param map 		Current ResourceMap registry entry 
		 * @return Object 	Reference to object instance whose property will be modified.
		 * 
		 */
		private function resolveEndPoint(map:ResourceSetter):Object {	   	 
			var results : Object = null;
			
			try {
				results = InjectorUtils.resolveEndPoint(map.target, map.property);
			} catch (e:Error) {
				logError(map,ERROR_UNKNOWN_NODE,e.message);
			}
			
			return results;
		}
		
		/**
		 * Determine the "true" property to modify in the target endpoint
		 * e.g.    "lblButton.label" --> resolved property === "label"
		 *  
		 * @param map 		Current ResourceMap registry entry 
		 * @return String 	Property key in the "endPoint" target
		 * 
		 */
		private function resolveProperty(map:ResourceSetter):String {
			return InjectorUtils.resolveProperty(map.property);
		}
		
		private function logError(map:ResourceSetter,errorType:String,node:String=null ):void {
			var targetID : String = getTargetIdentifier(map.target);
			var details  : String = "";
			switch(errorType) {
				case ERROR_UNKNOWN_PROPERTY : 
				{
					details = StringUtil.substitute(errorType, [targetID, map.property, 	map.key													 ]);		
					log.warn(details);
					break;
				}
				case ERROR_UNKNOWN_DATATYPE : {
					details = StringUtil.substitute(errorType, [map.type, map.key, 		targetID, 	map.property]);
					log.error(details);
					break;	
				}
				case ERROR_UNKNOWN_NODE     : 
				{
					details = StringUtil.substitute(errorType, [targetID, map.property, 	map.key, 	node        ]);
					log.warn(details);
					break;	
				}
				case ERROR_UNKNOWN_BUNDLE   : 
				{
					details = StringUtil.substitute(errorType, [targetID                                          ]);
					log.error(details);
					break;
				}
				case ERROR_KEY_VALUE_MISSING: 
				{
					details = StringUtil.substitute(errorType, [ map.bundleName,	map.key						]);
					log.error(details);
					break;
				}
			}
			
			function getTargetIdentifier(inst:Object):String {
				var results : String = (inst != null) ? getQualifiedClassName( inst ) : "<???>";
				
				if (inst && inst.hasOwnProperty("id")) {
					results = (inst["id"] != null) ? inst["id"] : results;
				}
				
				return results;
			}
		}
		
		private static var _counter : int = 0;
		
		private static const ERROR_UNKNOWN_PROPERTY : String = "-> Target {0}['{1}'] is unknown for resource key '{2}'.";
		private static const ERROR_UNKNOWN_DATATYPE : String = "-> Unknown data type {0} when mapping resource key '{1}' to {2}[{3}].";
		private static const ERROR_UNKNOWN_NODE     : String = "-> Unresolved node '{3}' in property {0}[{1}] for resource key '{2}'.";
		private static const ERROR_UNKNOWN_BUNDLE   : String = "-> Unknown or unspecified bundlename for target '{0}'!";
		private static const ERROR_KEY_VALUE_MISSING: String = "-> Property bundle '{0}' does not have the resource key '{1}'!";
		
		private var _cached          : Object           = null;
		private var _registry        : Dictionary       = new Dictionary(true);
		private var _owner           : IEventDispatcher = null;
		private var _initialized     : Boolean          = false;
		private var _resourceManager : IResourceManager = null;
		
		private namespace self;
	}
}

