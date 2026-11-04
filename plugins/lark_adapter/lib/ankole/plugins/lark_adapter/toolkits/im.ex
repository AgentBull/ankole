defmodule Ankole.Plugins.LarkAdapter.Toolkits.IM do
  @moduledoc "Explicit lark_im Toolkit contracts, based on the Lark OpenAPI SDK models."
  alias Ankole.Connectors.ToolSpec

  @contracts Torque.decode!(~S"""
             [
               {
                 "name": "im_send_message",
                 "description": "Im send message.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "receive_id_type": {
                       "type": "string"
                     },
                     "receive_id": {
                       "type": "string"
                     },
                     "msg_type": {
                       "type": "string"
                     },
                     "content": {
                       "oneOf": [
                         {
                           "type": "string"
                         },
                         {
                           "type": "object"
                         }
                       ]
                     },
                     "uuid": {
                       "type": "string"
                     },
                     "principal_uid": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "msg_type",
                     "content"
                   ],
                   "additionalProperties": false,
                   "anyOf": [
                     {
                       "required": [
                         "receive_id"
                       ]
                     },
                     {
                       "required": [
                         "principal_uid"
                       ]
                     }
                   ]
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "root_id": {
                       "type": "string"
                     },
                     "parent_id": {
                       "type": "string"
                     },
                     "thread_id": {
                       "type": "string"
                     },
                     "msg_type": {
                       "type": "string"
                     },
                     "create_time": {
                       "type": "string"
                     },
                     "update_time": {
                       "type": "string"
                     },
                     "deleted": {
                       "type": "boolean"
                     },
                     "updated": {
                       "type": "boolean"
                     },
                     "chat_id": {
                       "type": "string"
                     },
                     "sender": {
                       "type": "object",
                       "properties": {
                         "id": {
                           "type": "string"
                         },
                         "id_type": {
                           "type": "string"
                         },
                         "sender_type": {
                           "type": "string"
                         },
                         "tenant_key": {
                           "type": "string"
                         },
                         "sender_name": {
                           "type": "string"
                         },
                         "open_bot_id": {
                           "type": "string"
                         },
                         "sender_i18n_names": {
                           "type": "object",
                           "properties": {
                             "zh_cn": {
                               "type": "string"
                             },
                             "en_us": {
                               "type": "string"
                             },
                             "ja_jp": {
                               "type": "string"
                             }
                           }
                         }
                       }
                     },
                     "body": {
                       "type": "object",
                       "properties": {
                         "content": {
                           "type": "string"
                         }
                       }
                     },
                     "mentions": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "key": {
                             "type": "string"
                           },
                           "id": {
                             "type": "string"
                           },
                           "id_type": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "tenant_key": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "upper_message_id": {
                       "type": "string"
                     },
                     "message_app_link": {
                       "type": "string"
                     },
                     "message_position": {
                       "type": "string"
                     },
                     "thread_message_position": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/im/v1/messages",
                   "query": [
                     "receive_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_reply_message",
                 "description": "Im reply message.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "content": {
                       "oneOf": [
                         {
                           "type": "string"
                         },
                         {
                           "type": "object"
                         }
                       ]
                     },
                     "msg_type": {
                       "type": "string"
                     },
                     "reply_in_thread": {
                       "type": "boolean"
                     },
                     "uuid": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "message_id",
                     "msg_type",
                     "content"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "root_id": {
                       "type": "string"
                     },
                     "parent_id": {
                       "type": "string"
                     },
                     "thread_id": {
                       "type": "string"
                     },
                     "msg_type": {
                       "type": "string"
                     },
                     "create_time": {
                       "type": "string"
                     },
                     "update_time": {
                       "type": "string"
                     },
                     "deleted": {
                       "type": "boolean"
                     },
                     "updated": {
                       "type": "boolean"
                     },
                     "chat_id": {
                       "type": "string"
                     },
                     "sender": {
                       "type": "object",
                       "properties": {
                         "id": {
                           "type": "string"
                         },
                         "id_type": {
                           "type": "string"
                         },
                         "sender_type": {
                           "type": "string"
                         },
                         "tenant_key": {
                           "type": "string"
                         },
                         "sender_name": {
                           "type": "string"
                         },
                         "open_bot_id": {
                           "type": "string"
                         },
                         "sender_i18n_names": {
                           "type": "object",
                           "properties": {
                             "zh_cn": {
                               "type": "string"
                             },
                             "en_us": {
                               "type": "string"
                             },
                             "ja_jp": {
                               "type": "string"
                             }
                           }
                         }
                       }
                     },
                     "body": {
                       "type": "object",
                       "properties": {
                         "content": {
                           "type": "string"
                         }
                       }
                     },
                     "mentions": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "key": {
                             "type": "string"
                           },
                           "id": {
                             "type": "string"
                           },
                           "id_type": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "tenant_key": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "upper_message_id": {
                       "type": "string"
                     },
                     "message_app_link": {
                       "type": "string"
                     },
                     "message_position": {
                       "type": "string"
                     },
                     "thread_message_position": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/im/v1/messages/:message_id/reply",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_update_message",
                 "description": "Im update message.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "msg_type": {
                       "type": "string"
                     },
                     "content": {
                       "oneOf": [
                         {
                           "type": "string"
                         },
                         {
                           "type": "object"
                         }
                       ]
                     }
                   },
                   "required": [
                     "message_id",
                     "msg_type",
                     "content"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "root_id": {
                       "type": "string"
                     },
                     "parent_id": {
                       "type": "string"
                     },
                     "thread_id": {
                       "type": "string"
                     },
                     "msg_type": {
                       "type": "string"
                     },
                     "create_time": {
                       "type": "string"
                     },
                     "update_time": {
                       "type": "string"
                     },
                     "deleted": {
                       "type": "boolean"
                     },
                     "updated": {
                       "type": "boolean"
                     },
                     "chat_id": {
                       "type": "string"
                     },
                     "sender": {
                       "type": "object",
                       "properties": {
                         "id": {
                           "type": "string"
                         },
                         "id_type": {
                           "type": "string"
                         },
                         "sender_type": {
                           "type": "string"
                         },
                         "tenant_key": {
                           "type": "string"
                         },
                         "sender_name": {
                           "type": "string"
                         },
                         "open_bot_id": {
                           "type": "string"
                         },
                         "sender_i18n_names": {
                           "type": "object",
                           "properties": {
                             "zh_cn": {
                               "type": "string"
                             },
                             "en_us": {
                               "type": "string"
                             },
                             "ja_jp": {
                               "type": "string"
                             }
                           }
                         }
                       }
                     },
                     "body": {
                       "type": "object",
                       "properties": {
                         "content": {
                           "type": "string"
                         }
                       }
                     },
                     "mentions": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "key": {
                             "type": "string"
                           },
                           "id": {
                             "type": "string"
                           },
                           "id_type": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "tenant_key": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "upper_message_id": {
                       "type": "string"
                     },
                     "message_app_link": {
                       "type": "string"
                     },
                     "message_position": {
                       "type": "string"
                     },
                     "thread_message_position": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "PUT",
                   "path": "/open-apis/im/v1/messages/:message_id",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_delete_message",
                 "description": "Im delete message.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "message_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "DELETE",
                   "path": "/open-apis/im/v1/messages/:message_id",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": []
               },
               {
                 "name": "im_get_message",
                 "description": "Im get message.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "card_msg_content_type": {
                       "type": "string"
                     },
                     "with_sender_name": {
                       "type": "boolean"
                     }
                   },
                   "required": [
                     "message_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "message_id": {
                             "type": "string"
                           },
                           "root_id": {
                             "type": "string"
                           },
                           "parent_id": {
                             "type": "string"
                           },
                           "thread_id": {
                             "type": "string"
                           },
                           "msg_type": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "update_time": {
                             "type": "string"
                           },
                           "deleted": {
                             "type": "boolean"
                           },
                           "updated": {
                             "type": "boolean"
                           },
                           "chat_id": {
                             "type": "string"
                           },
                           "sender": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "id_type": {
                                 "type": "string"
                               },
                               "sender_type": {
                                 "type": "string"
                               },
                               "tenant_key": {
                                 "type": "string"
                               },
                               "sender_name": {
                                 "type": "string"
                               },
                               "open_bot_id": {
                                 "type": "string"
                               },
                               "sender_i18n_names": {
                                 "type": "object",
                                 "properties": {
                                   "zh_cn": {
                                     "type": "string"
                                   },
                                   "en_us": {
                                     "type": "string"
                                   },
                                   "ja_jp": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           },
                           "body": {
                             "type": "object",
                             "properties": {
                               "content": {
                                 "type": "string"
                               }
                             }
                           },
                           "mentions": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "key": {
                                   "type": "string"
                                 },
                                 "id": {
                                   "type": "string"
                                 },
                                 "id_type": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "tenant_key": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "upper_message_id": {
                             "type": "string"
                           },
                           "message_app_link": {
                             "type": "string"
                           },
                           "message_position": {
                             "type": "string"
                           },
                           "thread_message_position": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/messages/:message_id",
                   "query": [
                     "user_id_type",
                     "card_msg_content_type",
                     "with_sender_name"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_list_messages",
                 "description": "Im list messages.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "container_id_type": {
                       "type": "string"
                     },
                     "container_id": {
                       "type": "string"
                     },
                     "start_time": {
                       "type": "string"
                     },
                     "end_time": {
                       "type": "string"
                     },
                     "sort_type": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "card_msg_content_type": {
                       "type": "string"
                     },
                     "only_thread_root_messages": {
                       "type": "boolean"
                     },
                     "with_sender_name": {
                       "type": "boolean"
                     }
                   },
                   "required": [
                     "container_id_type",
                     "container_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "has_more": {
                       "type": "boolean"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "message_id": {
                             "type": "string"
                           },
                           "root_id": {
                             "type": "string"
                           },
                           "parent_id": {
                             "type": "string"
                           },
                           "thread_id": {
                             "type": "string"
                           },
                           "msg_type": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "update_time": {
                             "type": "string"
                           },
                           "deleted": {
                             "type": "boolean"
                           },
                           "updated": {
                             "type": "boolean"
                           },
                           "chat_id": {
                             "type": "string"
                           },
                           "sender": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "id_type": {
                                 "type": "string"
                               },
                               "sender_type": {
                                 "type": "string"
                               },
                               "tenant_key": {
                                 "type": "string"
                               },
                               "sender_name": {
                                 "type": "string"
                               },
                               "open_bot_id": {
                                 "type": "string"
                               },
                               "sender_i18n_names": {
                                 "type": "object",
                                 "properties": {
                                   "zh_cn": {
                                     "type": "string"
                                   },
                                   "en_us": {
                                     "type": "string"
                                   },
                                   "ja_jp": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           },
                           "body": {
                             "type": "object",
                             "properties": {
                               "content": {
                                 "type": "string"
                               }
                             }
                           },
                           "mentions": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "key": {
                                   "type": "string"
                                 },
                                 "id": {
                                   "type": "string"
                                 },
                                 "id_type": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "tenant_key": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "upper_message_id": {
                             "type": "string"
                           },
                           "message_app_link": {
                             "type": "string"
                           },
                           "message_position": {
                             "type": "string"
                           },
                           "thread_message_position": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/messages",
                   "query": [
                     "container_id_type",
                     "container_id",
                     "start_time",
                     "end_time",
                     "sort_type",
                     "page_size",
                     "page_token",
                     "card_msg_content_type",
                     "only_thread_root_messages",
                     "with_sender_name"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_list_thread_messages",
                 "description": "Im list thread messages.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "start_time": {
                       "type": "string"
                     },
                     "end_time": {
                       "type": "string"
                     },
                     "sort_type": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "card_msg_content_type": {
                       "type": "string"
                     },
                     "only_thread_root_messages": {
                       "type": "boolean"
                     },
                     "with_sender_name": {
                       "type": "boolean"
                     },
                     "thread_id": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "thread_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "has_more": {
                       "type": "boolean"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "message_id": {
                             "type": "string"
                           },
                           "root_id": {
                             "type": "string"
                           },
                           "parent_id": {
                             "type": "string"
                           },
                           "thread_id": {
                             "type": "string"
                           },
                           "msg_type": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "update_time": {
                             "type": "string"
                           },
                           "deleted": {
                             "type": "boolean"
                           },
                           "updated": {
                             "type": "boolean"
                           },
                           "chat_id": {
                             "type": "string"
                           },
                           "sender": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "id_type": {
                                 "type": "string"
                               },
                               "sender_type": {
                                 "type": "string"
                               },
                               "tenant_key": {
                                 "type": "string"
                               },
                               "sender_name": {
                                 "type": "string"
                               },
                               "open_bot_id": {
                                 "type": "string"
                               },
                               "sender_i18n_names": {
                                 "type": "object",
                                 "properties": {
                                   "zh_cn": {
                                     "type": "string"
                                   },
                                   "en_us": {
                                     "type": "string"
                                   },
                                   "ja_jp": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           },
                           "body": {
                             "type": "object",
                             "properties": {
                               "content": {
                                 "type": "string"
                               }
                             }
                           },
                           "mentions": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "key": {
                                   "type": "string"
                                 },
                                 "id": {
                                   "type": "string"
                                 },
                                 "id_type": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "tenant_key": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "upper_message_id": {
                             "type": "string"
                           },
                           "message_app_link": {
                             "type": "string"
                           },
                           "message_position": {
                             "type": "string"
                           },
                           "thread_message_position": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/messages",
                   "query": [
                     "container_id_type",
                     "container_id",
                     "start_time",
                     "end_time",
                     "sort_type",
                     "page_size",
                     "page_token",
                     "card_msg_content_type",
                     "only_thread_root_messages",
                     "with_sender_name"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_upload_file",
                 "description": "Im upload file.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "file_type": {
                       "type": "string"
                     },
                     "file_name": {
                       "type": "string"
                     },
                     "duration": {
                       "type": "integer"
                     },
                     "file_ref": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "file_ref",
                     "file_type",
                     "file_name"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "file_key": {
                       "type": "string"
                     },
                     "image_key": {"type": "string"}
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/im/v1/files",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_download_resource",
                 "description": "Im download resource.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "file_key": {
                       "type": "string"
                     },
                     "type": {
                       "type": "string"
                     },
                     "destination": {
                       "type": "object",
                       "properties": {
                         "page_id": {
                           "type": "string"
                         },
                         "role": {
                           "type": "string",
                           "enum": [
                             "file",
                             "asset",
                             "attachment"
                           ]
                         },
                         "name": {
                           "type": "string"
                         },
                         "base_object_id": {
                           "type": [
                             "string",
                             "null"
                           ]
                         },
                         "content_type": {
                           "type": "string"
                         }
                       },
                       "required": [
                         "page_id",
                         "role",
                         "name"
                       ],
                       "additionalProperties": false
                     }
                   },
                   "required": [
                     "message_id",
                     "file_key",
                     "type",
                     "destination"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "file_ref": {
                       "type": "string"
                     },
                     "size": {
                       "type": "integer"
                     },
                     "content_type": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "file_ref"
                   ]
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/messages/:message_id/resources/:file_key",
                   "query": [
                     "type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_add_reaction",
                 "description": "Im add reaction.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "reaction_type": {
                       "type": "object",
                       "properties": {
                         "emoji_type": {
                           "type": "string"
                         }
                       }
                     }
                   },
                   "required": [
                     "message_id",
                     "reaction_type"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "reaction_id": {
                       "type": "string"
                     },
                     "operator": {
                       "type": "object",
                       "properties": {
                         "operator_id": {
                           "type": "string"
                         },
                         "operator_type": {
                           "type": "string"
                         }
                       }
                     },
                     "action_time": {
                       "type": "string"
                     },
                     "reaction_type": {
                       "type": "object",
                       "properties": {
                         "emoji_type": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/im/v1/messages/:message_id/reactions",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_delete_reaction",
                 "description": "Im delete reaction.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "reaction_id": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "message_id",
                     "reaction_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "reaction_id": {
                       "type": "string"
                     },
                     "operator": {
                       "type": "object",
                       "properties": {
                         "operator_id": {
                           "type": "string"
                         },
                         "operator_type": {
                           "type": "string"
                         }
                       }
                     },
                     "action_time": {
                       "type": "string"
                     },
                     "reaction_type": {
                       "type": "object",
                       "properties": {
                         "emoji_type": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "DELETE",
                   "path": "/open-apis/im/v1/messages/:message_id/reactions/:reaction_id",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": []
               },
               {
                 "name": "im_pin_message",
                 "description": "Im pin message.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "message_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "pin": {
                       "type": "object",
                       "properties": {
                         "message_id": {
                           "type": "string"
                         },
                         "chat_id": {
                           "type": "string"
                         },
                         "operator_id": {
                           "type": "string"
                         },
                         "operator_id_type": {
                           "type": "string"
                         },
                         "create_time": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/im/v1/pins",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_urgent_message",
                 "description": "Im urgent message.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "message_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "user_id_list": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "channel": {
                       "type": "string",
                       "enum": [
                         "app",
                         "sms",
                         "phone"
                       ]
                     }
                   },
                   "required": [
                     "message_id",
                     "user_id_list"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "invalid_user_id_list": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "PATCH",
                   "path": "/open-apis/im/v1/messages/:message_id/urgent_app",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_list_chats",
                 "description": "Im list chats.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "sort_type": {
                       "type": "string"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "types": {
                       "type": "string"
                     }
                   },
                   "required": [],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "chat_id": {
                             "type": "string"
                           },
                           "avatar": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "description": {
                             "type": "string"
                           },
                           "owner_id": {
                             "type": "string"
                           },
                           "owner_id_type": {
                             "type": "string"
                           },
                           "external": {
                             "type": "boolean"
                           },
                           "tenant_key": {
                             "type": "string"
                           },
                           "labels": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "chat_status": {
                             "type": "string"
                           },
                           "chat_mode": {
                             "type": "string"
                           },
                           "p2p_target_type": {
                             "type": "string"
                           },
                           "p2p_target_id": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "has_more": {
                       "type": "boolean"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/chats",
                   "query": [
                     "user_id_type",
                     "sort_type",
                     "page_token",
                     "page_size",
                     "types"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_get_chat",
                 "description": "Im get chat.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "chat_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     }
                   },
                   "required": [
                     "chat_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "avatar": {
                       "type": "string"
                     },
                     "name": {
                       "type": "string"
                     },
                     "description": {
                       "type": "string"
                     },
                     "i18n_names": {
                       "type": "object",
                       "properties": {
                         "zh_cn": {
                           "type": "string"
                         },
                         "en_us": {
                           "type": "string"
                         },
                         "ja_jp": {
                           "type": "string"
                         }
                       }
                     },
                     "add_member_permission": {
                       "type": "string"
                     },
                     "share_card_permission": {
                       "type": "string"
                     },
                     "at_all_permission": {
                       "type": "string"
                     },
                     "edit_permission": {
                       "type": "string"
                     },
                     "owner_id_type": {
                       "type": "string"
                     },
                     "owner_id": {
                       "type": "string"
                     },
                     "user_manager_id_list": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "bot_manager_id_list": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "group_message_type": {
                       "type": "string"
                     },
                     "chat_mode": {
                       "type": "string"
                     },
                     "chat_type": {
                       "type": "string"
                     },
                     "chat_tag": {
                       "type": "string"
                     },
                     "join_message_visibility": {
                       "type": "string"
                     },
                     "leave_message_visibility": {
                       "type": "string"
                     },
                     "membership_approval": {
                       "type": "string"
                     },
                     "moderation_permission": {
                       "type": "string"
                     },
                     "external": {
                       "type": "boolean"
                     },
                     "tenant_key": {
                       "type": "string"
                     },
                     "user_count": {
                       "type": "string"
                     },
                     "bot_count": {
                       "type": "string"
                     },
                     "labels": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "toolkit_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "restricted_mode_setting": {
                       "type": "object",
                       "properties": {
                         "status": {
                           "type": "boolean"
                         },
                         "screenshot_has_permission_setting": {
                           "type": "string"
                         },
                         "download_has_permission_setting": {
                           "type": "string"
                         },
                         "message_has_permission_setting": {
                           "type": "string"
                         }
                       }
                     },
                     "urgent_setting": {
                       "type": "string"
                     },
                     "video_conference_setting": {
                       "type": "string"
                     },
                     "pin_manage_setting": {
                       "type": "string"
                     },
                     "hide_member_count_setting": {
                       "type": "string"
                     },
                     "chat_status": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/chats/:chat_id",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_search_chats",
                 "description": "Im search chats.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "query": {
                       "type": "string"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     }
                   },
                   "required": [],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "chat_id": {
                             "type": "string"
                           },
                           "avatar": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "description": {
                             "type": "string"
                           },
                           "owner_id": {
                             "type": "string"
                           },
                           "owner_id_type": {
                             "type": "string"
                           },
                           "external": {
                             "type": "boolean"
                           },
                           "tenant_key": {
                             "type": "string"
                           },
                           "labels": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "chat_status": {
                             "type": "string"
                           },
                           "chat_mode": {
                             "type": "string"
                           },
                           "p2p_target_type": {
                             "type": "string"
                           },
                           "p2p_target_id": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "has_more": {
                       "type": "boolean"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/chats/search",
                   "query": [
                     "user_id_type",
                     "query",
                     "page_token",
                     "page_size"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               },
               {
                 "name": "im_list_chat_members",
                 "description": "Im list chat members.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "chat_id": {
                       "type": "string"
                     },
                     "member_id_type": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "check_security_conf": {
                       "type": "boolean"
                     }
                   },
                   "required": [
                     "chat_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "member_id_type": {
                             "type": "string"
                           },
                           "member_id": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "tenant_key": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "has_more": {
                       "type": "boolean"
                     },
                     "member_total": {
                       "type": "integer"
                     },
                     "trigger_security_conf_limit": {
                       "type": "boolean"
                     },
                     "security_conf_limit": {
                       "type": "integer"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/im/v1/chats/:chat_id/members",
                   "query": [
                     "member_id_type",
                     "page_size",
                     "page_token",
                     "check_security_conf"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": []
               }
             ]
             """)
  def tools do
    Enum.map(@contracts, fn contract ->
      %ToolSpec{
        toolkit: "lark_im",
        name: contract["name"],
        description: contract["description"],
        input_schema: contract["input_schema"],
        output_schema: contract["output_schema"],
        operation: contract["operation"],
        subject_policy: :any_principal,
        upstream_auth: :app_token,
        scopes: contract["scopes"],
        annotations:
          ToolSpec.annotations(
            contract["read_only"],
            contract["idempotent"],
            contract["destructive"]
          )
      }
    end)
  end
end
