defmodule Ankole.Plugins.LarkAdapter.Toolkits.Tasks do
  @moduledoc "Explicit lark_tasks Toolkit contracts, based on the Lark OpenAPI SDK models."
  alias Ankole.Connectors.ToolSpec

  @contracts Torque.decode!(~S"""
             [
               {
                 "name": "tasks_create",
                 "description": "Tasks create.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "summary": {
                       "type": "string"
                     },
                     "description": {
                       "type": "string"
                     },
                     "due": {
                       "type": "object",
                       "properties": {
                         "timestamp": {
                           "type": "string"
                         },
                         "is_all_day": {
                           "type": "boolean"
                         }
                       }
                     },
                     "origin": {
                       "type": "object",
                       "properties": {
                         "platform_i18n_name": {
                           "type": "object",
                           "properties": {
                             "en_us": {
                               "type": "string"
                             },
                             "zh_cn": {
                               "type": "string"
                             },
                             "zh_hk": {
                               "type": "string"
                             },
                             "zh_tw": {
                               "type": "string"
                             },
                             "ja_jp": {
                               "type": "string"
                             },
                             "fr_fr": {
                               "type": "string"
                             },
                             "it_it": {
                               "type": "string"
                             },
                             "de_de": {
                               "type": "string"
                             },
                             "ru_ru": {
                               "type": "string"
                             },
                             "th_th": {
                               "type": "string"
                             },
                             "es_es": {
                               "type": "string"
                             },
                             "ko_kr": {
                               "type": "string"
                             }
                           }
                         },
                         "href": {
                           "type": "object",
                           "properties": {
                             "url": {
                               "type": "string"
                             },
                             "title": {
                               "type": "string"
                             }
                           }
                         },
                         "refer_resources": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "resource_id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "source_message": {
                                 "type": "object",
                                 "properties": {
                                   "message_id": {
                                     "type": "string"
                                   },
                                   "content": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "unavailable_reason": {
                                 "type": "string"
                               }
                             }
                           }
                         }
                       }
                     },
                     "extra": {
                       "type": "string"
                     },
                     "completed_at": {
                       "type": "string"
                     },
                     "members": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "type": {
                             "type": "string"
                           },
                           "role": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "principal_uid": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "repeat_rule": {
                       "type": "string"
                     },
                     "custom_complete": {
                       "type": "object",
                       "properties": {
                         "pc": {
                           "type": "object",
                           "properties": {
                             "href": {
                               "type": "string"
                             },
                             "tip": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         },
                         "ios": {
                           "type": "object",
                           "properties": {
                             "href": {
                               "type": "string"
                             },
                             "tip": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         },
                         "android": {
                           "type": "object",
                           "properties": {
                             "href": {
                               "type": "string"
                             },
                             "tip": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         }
                       }
                     },
                     "tasklists": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "tasklist_guid": {
                             "type": "string"
                           },
                           "section_guid": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "client_token": {
                       "type": "string"
                     },
                     "start": {
                       "type": "object",
                       "properties": {
                         "timestamp": {
                           "type": "string"
                         },
                         "is_all_day": {
                           "type": "boolean"
                         }
                       }
                     },
                     "reminders": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "relative_fire_minute": {
                             "type": "integer"
                           }
                         }
                       }
                     },
                     "mode": {
                       "type": "integer"
                     },
                     "is_milestone": {
                       "type": "boolean"
                     },
                     "custom_fields": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "guid": {
                             "type": "string"
                           },
                           "number_value": {
                             "type": "string"
                           },
                           "member_value": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 },
                                 "role": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "principal_uid": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "datetime_value": {
                             "type": "string"
                           },
                           "single_select_value": {
                             "type": "string"
                           },
                           "multi_select_value": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "text_value": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "docx_source": {
                       "type": "object",
                       "properties": {
                         "token": {
                           "type": "string"
                         },
                         "block_id": {
                           "type": "string"
                         }
                       }
                     },
                     "positive_reminders": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "relative_fire_minute": {
                             "type": "integer"
                           }
                         }
                       }
                     },
                     "agent_task_status": {
                       "type": "integer"
                     },
                     "agent_task_progress": {
                       "type": "string"
                     },
                     "text_deliveries": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "summary"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/tasks",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasks_patch",
                 "description": "Tasks patch.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "task": {
                       "type": "object",
                       "properties": {
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "principal_uid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "client_token": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "docx_source": {
                           "type": "object",
                           "properties": {
                             "token": {
                               "type": "string"
                             },
                             "block_id": {
                               "type": "string"
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "update_fields": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "task_guid",
                     "task",
                     "update_fields"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "PATCH",
                   "path": "/open-apis/task/v2/tasks/:task_guid",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasks_delete",
                 "description": "Tasks delete.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "task_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "DELETE",
                   "path": "/open-apis/task/v2/tasks/:task_guid",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasks_get",
                 "description": "Tasks get.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "task_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/task/v2/tasks/:task_guid",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:read"
                 ]
               },
               {
                 "name": "tasks_list",
                 "description": "Tasks list.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "completed": {
                       "type": "boolean"
                     },
                     "type": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "agent_task_status": {
                       "type": "integer"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
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
                           "guid": {
                             "type": "string"
                           },
                           "summary": {
                             "type": "string"
                           },
                           "description": {
                             "type": "string"
                           },
                           "due": {
                             "type": "object",
                             "properties": {
                               "timestamp": {
                                 "type": "string"
                               },
                               "is_all_day": {
                                 "type": "boolean"
                               }
                             }
                           },
                           "reminders": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "relative_fire_minute": {
                                   "type": "integer"
                                 }
                               }
                             }
                           },
                           "creator": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           },
                           "members": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 },
                                 "role": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "completed_at": {
                             "type": "string"
                           },
                           "attachments": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "guid": {
                                   "type": "string"
                                 },
                                 "file_token": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "size": {
                                   "type": "integer"
                                 },
                                 "resource": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "uploader": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "is_cover": {
                                   "type": "boolean"
                                 },
                                 "uploaded_at": {
                                   "type": "string"
                                 },
                                 "url": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "origin": {
                             "type": "object",
                             "properties": {
                               "platform_i18n_name": {
                                 "type": "object",
                                 "properties": {
                                   "en_us": {
                                     "type": "string"
                                   },
                                   "zh_cn": {
                                     "type": "string"
                                   },
                                   "zh_hk": {
                                     "type": "string"
                                   },
                                   "zh_tw": {
                                     "type": "string"
                                   },
                                   "ja_jp": {
                                     "type": "string"
                                   },
                                   "fr_fr": {
                                     "type": "string"
                                   },
                                   "it_it": {
                                     "type": "string"
                                   },
                                   "de_de": {
                                     "type": "string"
                                   },
                                   "ru_ru": {
                                     "type": "string"
                                   },
                                   "th_th": {
                                     "type": "string"
                                   },
                                   "es_es": {
                                     "type": "string"
                                   },
                                   "ko_kr": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "href": {
                                 "type": "object",
                                 "properties": {
                                   "url": {
                                     "type": "string"
                                   },
                                   "title": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "refer_resources": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               }
                             }
                           },
                           "extra": {
                             "type": "string"
                           },
                           "tasklists": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "tasklist_guid": {
                                   "type": "string"
                                 },
                                 "section_guid": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "repeat_rule": {
                             "type": "string"
                           },
                           "parent_task_guid": {
                             "type": "string"
                           },
                           "mode": {
                             "type": "integer"
                           },
                           "source": {
                             "type": "integer"
                           },
                           "custom_complete": {
                             "type": "object",
                             "properties": {
                               "pc": {
                                 "type": "object",
                                 "properties": {
                                   "href": {
                                     "type": "string"
                                   },
                                   "tip": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               },
                               "ios": {
                                 "type": "object",
                                 "properties": {
                                   "href": {
                                     "type": "string"
                                   },
                                   "tip": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               },
                               "android": {
                                 "type": "object",
                                 "properties": {
                                   "href": {
                                     "type": "string"
                                   },
                                   "tip": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           },
                           "task_id": {
                             "type": "string"
                           },
                           "created_at": {
                             "type": "string"
                           },
                           "updated_at": {
                             "type": "string"
                           },
                           "status": {
                             "type": "string"
                           },
                           "url": {
                             "type": "string"
                           },
                           "start": {
                             "type": "object",
                             "properties": {
                               "timestamp": {
                                 "type": "string"
                               },
                               "is_all_day": {
                                 "type": "boolean"
                               }
                             }
                           },
                           "subtask_count": {
                             "type": "integer"
                           },
                           "is_milestone": {
                             "type": "boolean"
                           },
                           "custom_fields": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "guid": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 },
                                 "number_value": {
                                   "type": "string"
                                 },
                                 "datetime_value": {
                                   "type": "string"
                                 },
                                 "member_value": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 },
                                 "single_select_value": {
                                   "type": "string"
                                 },
                                 "multi_select_value": {
                                   "type": "array",
                                   "items": {
                                     "type": "string"
                                   }
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "text_value": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "dependencies": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "type": {
                                   "type": "string"
                                 },
                                 "task_guid": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "assignee_related": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "completed_at": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "positive_reminders": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "relative_fire_minute": {
                                   "type": "integer"
                                 }
                               }
                             }
                           },
                           "agent_task_status": {
                             "type": "integer"
                           },
                           "agent_task_progress": {
                             "type": "string"
                           },
                           "text_deliveries": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "attachment_deliveries": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "guid": {
                                   "type": "string"
                                 },
                                 "file_token": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "size": {
                                   "type": "integer"
                                 },
                                 "resource": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "uploader": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "is_cover": {
                                   "type": "boolean"
                                 },
                                 "uploaded_at": {
                                   "type": "string"
                                 },
                                 "url": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "next_task_guid": {
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
                   "path": "/open-apis/task/v2/tasks",
                   "query": [
                     "page_size",
                     "page_token",
                     "completed",
                     "type",
                     "user_id_type",
                     "agent_task_status"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:read"
                 ]
               },
               {
                 "name": "tasks_complete",
                 "description": "Tasks complete.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "task_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "PATCH",
                   "path": "/open-apis/task/v2/tasks/:task_guid",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": true,
                 "destructive": false,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasks_uncomplete",
                 "description": "Tasks uncomplete.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "task_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "PATCH",
                   "path": "/open-apis/task/v2/tasks/:task_guid",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": true,
                 "destructive": false,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasks_manage_members",
                 "description": "Tasks manage members.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "members": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "type": {
                             "type": "string"
                           },
                           "role": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "principal_uid": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "client_token": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     },
                     "operation": {
                       "type": "string",
                       "enum": [
                         "add",
                         "remove"
                       ]
                     }
                   },
                   "required": [
                     "task_guid",
                     "operation"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/tasks/:task_guid/add_members",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasks_manage_reminders",
                 "description": "Tasks manage reminders.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "reminders": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "relative_fire_minute": {
                             "type": "integer"
                           }
                         }
                       }
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     },
                     "operation": {
                       "type": "string",
                       "enum": [
                         "add",
                         "remove"
                       ]
                     },
                     "reminder_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     }
                   },
                   "required": [
                     "task_guid",
                     "operation"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/tasks/:task_guid/add_reminders",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasklists_list",
                 "description": "Tasklists list.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
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
                           "guid": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "creator": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           },
                           "owner": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           },
                           "members": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 },
                                 "role": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "url": {
                             "type": "string"
                           },
                           "created_at": {
                             "type": "string"
                           },
                           "updated_at": {
                             "type": "string"
                           },
                           "archive_msec": {
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
                   "path": "/open-apis/task/v2/tasklists",
                   "query": [
                     "page_size",
                     "page_token",
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:tasklist:read"
                 ]
               },
               {
                 "name": "tasklists_get",
                 "description": "Tasklists get.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "tasklist_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "name": {
                           "type": "string"
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "owner": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "url": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "archive_msec": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/task/v2/tasklists/:tasklist_guid",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:tasklist:read"
                 ]
               },
               {
                 "name": "tasklists_create",
                 "description": "Tasklists create.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "name": {
                       "type": "string"
                     },
                     "client_token": {
                       "type": "string"
                     },
                     "members": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "type": {
                             "type": "string"
                           },
                           "role": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "principal_uid": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "owner": {
                       "type": "object",
                       "properties": {
                         "id": {
                           "type": "string"
                         },
                         "type": {
                           "type": "string"
                         },
                         "role": {
                           "type": "string"
                         },
                         "name": {
                           "type": "string"
                         },
                         "principal_uid": {
                           "type": "string"
                         }
                       }
                     },
                     "archive_tasklist": {
                       "type": "boolean"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "name"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "name": {
                           "type": "string"
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "owner": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "url": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "archive_msec": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/tasklists",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:tasklist:write"
                 ]
               },
               {
                 "name": "tasklists_patch",
                 "description": "Tasklists patch.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "tasklist": {
                       "type": "object",
                       "properties": {
                         "name": {
                           "type": "string"
                         },
                         "client_token": {
                           "type": "string"
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "principal_uid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "owner": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             },
                             "principal_uid": {
                               "type": "string"
                             }
                           }
                         },
                         "archive_tasklist": {
                           "type": "boolean"
                         }
                       }
                     },
                     "update_fields": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "origin_owner_to_role": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "tasklist_guid",
                     "tasklist",
                     "update_fields"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "name": {
                           "type": "string"
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "owner": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "url": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "archive_msec": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "PATCH",
                   "path": "/open-apis/task/v2/tasklists/:tasklist_guid",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:tasklist:write"
                 ]
               },
               {
                 "name": "tasklists_delete",
                 "description": "Tasklists delete.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist_guid": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "tasklist_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "DELETE",
                   "path": "/open-apis/task/v2/tasklists/:tasklist_guid",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "task:tasklist:write"
                 ]
               },
               {
                 "name": "tasklists_manage_members",
                 "description": "Tasklists manage members.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "members": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "type": {
                             "type": "string"
                           },
                           "role": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "principal_uid": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     },
                     "operation": {
                       "type": "string",
                       "enum": [
                         "add",
                         "remove"
                       ]
                     }
                   },
                   "required": [
                     "tasklist_guid",
                     "operation"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "tasklist": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "name": {
                           "type": "string"
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "owner": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "url": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "archive_msec": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/tasklists/:tasklist_guid/add_members",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:tasklist:write"
                 ]
               },
               {
                 "name": "tasklists_manage_tasks",
                 "description": "Tasklists manage tasks.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "tasklist_guid": {
                       "type": "string"
                     },
                     "section_guid": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     },
                     "operation": {
                       "type": "string",
                       "enum": [
                         "add",
                         "remove"
                       ]
                     }
                   },
                   "required": [
                     "task_guid",
                     "operation"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "task": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/tasks/:task_guid/add_tasklist",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:tasklist:write"
                 ]
               },
               {
                 "name": "task_sections_list",
                 "description": "Task sections list.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "resource_type": {
                       "type": "string"
                     },
                     "resource_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "update_msec": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
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
                           "guid": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "is_default": {
                             "type": "boolean"
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
                   "path": "/open-apis/task/v2/sections",
                   "query": [
                     "page_size",
                     "page_token",
                     "resource_type",
                     "resource_id",
                     "user_id_type",
                     "update_msec"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:section:read"
                 ]
               },
               {
                 "name": "task_sections_create",
                 "description": "Task sections create.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "name": {
                       "type": "string"
                     },
                     "resource_type": {
                       "type": "string"
                     },
                     "resource_id": {
                       "type": "string"
                     },
                     "insert_before": {
                       "type": "string"
                     },
                     "insert_after": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "name",
                     "resource_type",
                     "resource_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "section": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "name": {
                           "type": "string"
                         },
                         "resource_type": {
                           "type": "string"
                         },
                         "is_default": {
                           "type": "boolean"
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "tasklist": {
                           "type": "object",
                           "properties": {
                             "guid": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/sections",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:section:write"
                 ]
               },
               {
                 "name": "task_sections_patch",
                 "description": "Task sections patch.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "section_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "section": {
                       "type": "object",
                       "properties": {
                         "name": {
                           "type": "string"
                         },
                         "resource_type": {
                           "type": "string"
                         },
                         "resource_id": {
                           "type": "string"
                         },
                         "insert_before": {
                           "type": "string"
                         },
                         "insert_after": {
                           "type": "string"
                         }
                       }
                     },
                     "update_fields": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "section_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "section": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "name": {
                           "type": "string"
                         },
                         "resource_type": {
                           "type": "string"
                         },
                         "is_default": {
                           "type": "boolean"
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "tasklist": {
                           "type": "object",
                           "properties": {
                             "guid": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "PATCH",
                   "path": "/open-apis/task/v2/sections/:section_guid",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:section:write"
                 ]
               },
               {
                 "name": "task_sections_delete",
                 "description": "Task sections delete.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "section_guid": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "section_guid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "DELETE",
                   "path": "/open-apis/task/v2/sections/:section_guid",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "task:section:write"
                 ]
               },
               {
                 "name": "tasks_create_subtask",
                 "description": "Tasks create subtask.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "summary": {
                       "type": "string"
                     },
                     "description": {
                       "type": "string"
                     },
                     "due": {
                       "type": "object",
                       "properties": {
                         "timestamp": {
                           "type": "string"
                         },
                         "is_all_day": {
                           "type": "boolean"
                         }
                       }
                     },
                     "origin": {
                       "type": "object",
                       "properties": {
                         "platform_i18n_name": {
                           "type": "object",
                           "properties": {
                             "en_us": {
                               "type": "string"
                             },
                             "zh_cn": {
                               "type": "string"
                             },
                             "zh_hk": {
                               "type": "string"
                             },
                             "zh_tw": {
                               "type": "string"
                             },
                             "ja_jp": {
                               "type": "string"
                             },
                             "fr_fr": {
                               "type": "string"
                             },
                             "it_it": {
                               "type": "string"
                             },
                             "de_de": {
                               "type": "string"
                             },
                             "ru_ru": {
                               "type": "string"
                             },
                             "th_th": {
                               "type": "string"
                             },
                             "es_es": {
                               "type": "string"
                             },
                             "ko_kr": {
                               "type": "string"
                             }
                           }
                         },
                         "href": {
                           "type": "object",
                           "properties": {
                             "url": {
                               "type": "string"
                             },
                             "title": {
                               "type": "string"
                             }
                           }
                         },
                         "refer_resources": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "resource_id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "source_message": {
                                 "type": "object",
                                 "properties": {
                                   "message_id": {
                                     "type": "string"
                                   },
                                   "content": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "unavailable_reason": {
                                 "type": "string"
                               }
                             }
                           }
                         }
                       }
                     },
                     "extra": {
                       "type": "string"
                     },
                     "completed_at": {
                       "type": "string"
                     },
                     "members": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "type": {
                             "type": "string"
                           },
                           "role": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "principal_uid": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "repeat_rule": {
                       "type": "string"
                     },
                     "custom_complete": {
                       "type": "object",
                       "properties": {
                         "pc": {
                           "type": "object",
                           "properties": {
                             "href": {
                               "type": "string"
                             },
                             "tip": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         },
                         "ios": {
                           "type": "object",
                           "properties": {
                             "href": {
                               "type": "string"
                             },
                             "tip": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         },
                         "android": {
                           "type": "object",
                           "properties": {
                             "href": {
                               "type": "string"
                             },
                             "tip": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         }
                       }
                     },
                     "tasklists": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "tasklist_guid": {
                             "type": "string"
                           },
                           "section_guid": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "client_token": {
                       "type": "string"
                     },
                     "start": {
                       "type": "object",
                       "properties": {
                         "timestamp": {
                           "type": "string"
                         },
                         "is_all_day": {
                           "type": "boolean"
                         }
                       }
                     },
                     "reminders": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "relative_fire_minute": {
                             "type": "integer"
                           }
                         }
                       }
                     },
                     "mode": {
                       "type": "integer"
                     },
                     "is_milestone": {
                       "type": "boolean"
                     },
                     "custom_fields": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "guid": {
                             "type": "string"
                           },
                           "number_value": {
                             "type": "string"
                           },
                           "member_value": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 },
                                 "role": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "principal_uid": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "datetime_value": {
                             "type": "string"
                           },
                           "single_select_value": {
                             "type": "string"
                           },
                           "multi_select_value": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "text_value": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "docx_source": {
                       "type": "object",
                       "properties": {
                         "token": {
                           "type": "string"
                         },
                         "block_id": {
                           "type": "string"
                         }
                       }
                     },
                     "positive_reminders": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "relative_fire_minute": {
                             "type": "integer"
                           }
                         }
                       }
                     },
                     "agent_task_status": {
                       "type": "integer"
                     },
                     "agent_task_progress": {
                       "type": "string"
                     },
                     "text_deliveries": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "task_guid",
                     "summary"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "subtask": {
                       "type": "object",
                       "properties": {
                         "guid": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "due": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "members": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "completed_at": {
                           "type": "string"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "origin": {
                           "type": "object",
                           "properties": {
                             "platform_i18n_name": {
                               "type": "object",
                               "properties": {
                                 "en_us": {
                                   "type": "string"
                                 },
                                 "zh_cn": {
                                   "type": "string"
                                 },
                                 "zh_hk": {
                                   "type": "string"
                                 },
                                 "zh_tw": {
                                   "type": "string"
                                 },
                                 "ja_jp": {
                                   "type": "string"
                                 },
                                 "fr_fr": {
                                   "type": "string"
                                 },
                                 "it_it": {
                                   "type": "string"
                                 },
                                 "de_de": {
                                   "type": "string"
                                 },
                                 "ru_ru": {
                                   "type": "string"
                                 },
                                 "th_th": {
                                   "type": "string"
                                 },
                                 "es_es": {
                                   "type": "string"
                                 },
                                 "ko_kr": {
                                   "type": "string"
                                 }
                               }
                             },
                             "href": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "title": {
                                   "type": "string"
                                 }
                               }
                             },
                             "refer_resources": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "resource_id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "source_message": {
                                     "type": "object",
                                     "properties": {}
                                   },
                                   "unavailable_reason": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "extra": {
                           "type": "string"
                         },
                         "tasklists": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "tasklist_guid": {
                                 "type": "string"
                               },
                               "section_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "repeat_rule": {
                           "type": "string"
                         },
                         "parent_task_guid": {
                           "type": "string"
                         },
                         "mode": {
                           "type": "integer"
                         },
                         "source": {
                           "type": "integer"
                         },
                         "custom_complete": {
                           "type": "object",
                           "properties": {
                             "pc": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "ios": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             },
                             "android": {
                               "type": "object",
                               "properties": {
                                 "href": {
                                   "type": "string"
                                 },
                                 "tip": {
                                   "type": "object",
                                   "properties": {
                                     "en_us": {
                                       "type": "string"
                                     },
                                     "zh_cn": {
                                       "type": "string"
                                     },
                                     "zh_hk": {
                                       "type": "string"
                                     },
                                     "zh_tw": {
                                       "type": "string"
                                     },
                                     "ja_jp": {
                                       "type": "string"
                                     },
                                     "fr_fr": {
                                       "type": "string"
                                     },
                                     "it_it": {
                                       "type": "string"
                                     },
                                     "de_de": {
                                       "type": "string"
                                     },
                                     "ru_ru": {
                                       "type": "string"
                                     },
                                     "th_th": {
                                       "type": "string"
                                     },
                                     "es_es": {
                                       "type": "string"
                                     },
                                     "ko_kr": {
                                       "type": "string"
                                     }
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "task_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "url": {
                           "type": "string"
                         },
                         "start": {
                           "type": "object",
                           "properties": {
                             "timestamp": {
                               "type": "string"
                             },
                             "is_all_day": {
                               "type": "boolean"
                             }
                           }
                         },
                         "subtask_count": {
                           "type": "integer"
                         },
                         "is_milestone": {
                           "type": "boolean"
                         },
                         "custom_fields": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "number_value": {
                                 "type": "string"
                               },
                               "datetime_value": {
                                 "type": "string"
                               },
                               "member_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "single_select_value": {
                                 "type": "string"
                               },
                               "multi_select_value": {
                                 "type": "array",
                                 "items": {
                                   "type": "string"
                                 }
                               },
                               "name": {
                                 "type": "string"
                               },
                               "text_value": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "dependencies": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "task_guid": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "assignee_related": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "completed_at": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "positive_reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "relative_fire_minute": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "agent_task_status": {
                           "type": "integer"
                         },
                         "agent_task_progress": {
                           "type": "string"
                         },
                         "text_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "attachment_deliveries": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "guid": {
                                 "type": "string"
                               },
                               "file_token": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               },
                               "size": {
                                 "type": "integer"
                               },
                               "resource": {
                                 "type": "object",
                                 "properties": {
                                   "type": {
                                     "type": "string"
                                   },
                                   "id": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "uploader": {
                                 "type": "object",
                                 "properties": {
                                   "id": {
                                     "type": "string"
                                   },
                                   "type": {
                                     "type": "string"
                                   },
                                   "role": {
                                     "type": "string"
                                   },
                                   "name": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "is_cover": {
                                 "type": "boolean"
                               },
                               "uploaded_at": {
                                 "type": "string"
                               },
                               "url": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "next_task_guid": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/tasks/:task_guid/subtasks",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:write"
                 ]
               },
               {
                 "name": "tasks_list_subtasks",
                 "description": "Tasks list subtasks.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "task_guid": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "task_guid"
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
                           "guid": {
                             "type": "string"
                           },
                           "summary": {
                             "type": "string"
                           },
                           "description": {
                             "type": "string"
                           },
                           "due": {
                             "type": "object",
                             "properties": {
                               "timestamp": {
                                 "type": "string"
                               },
                               "is_all_day": {
                                 "type": "boolean"
                               }
                             }
                           },
                           "reminders": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "relative_fire_minute": {
                                   "type": "integer"
                                 }
                               }
                             }
                           },
                           "creator": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           },
                           "members": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 },
                                 "role": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "completed_at": {
                             "type": "string"
                           },
                           "attachments": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "guid": {
                                   "type": "string"
                                 },
                                 "file_token": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "size": {
                                   "type": "integer"
                                 },
                                 "resource": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "uploader": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "is_cover": {
                                   "type": "boolean"
                                 },
                                 "uploaded_at": {
                                   "type": "string"
                                 },
                                 "url": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "origin": {
                             "type": "object",
                             "properties": {
                               "platform_i18n_name": {
                                 "type": "object",
                                 "properties": {
                                   "en_us": {
                                     "type": "string"
                                   },
                                   "zh_cn": {
                                     "type": "string"
                                   },
                                   "zh_hk": {
                                     "type": "string"
                                   },
                                   "zh_tw": {
                                     "type": "string"
                                   },
                                   "ja_jp": {
                                     "type": "string"
                                   },
                                   "fr_fr": {
                                     "type": "string"
                                   },
                                   "it_it": {
                                     "type": "string"
                                   },
                                   "de_de": {
                                     "type": "string"
                                   },
                                   "ru_ru": {
                                     "type": "string"
                                   },
                                   "th_th": {
                                     "type": "string"
                                   },
                                   "es_es": {
                                     "type": "string"
                                   },
                                   "ko_kr": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "href": {
                                 "type": "object",
                                 "properties": {
                                   "url": {
                                     "type": "string"
                                   },
                                   "title": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "refer_resources": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               }
                             }
                           },
                           "extra": {
                             "type": "string"
                           },
                           "tasklists": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "tasklist_guid": {
                                   "type": "string"
                                 },
                                 "section_guid": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "repeat_rule": {
                             "type": "string"
                           },
                           "parent_task_guid": {
                             "type": "string"
                           },
                           "mode": {
                             "type": "integer"
                           },
                           "source": {
                             "type": "integer"
                           },
                           "custom_complete": {
                             "type": "object",
                             "properties": {
                               "pc": {
                                 "type": "object",
                                 "properties": {
                                   "href": {
                                     "type": "string"
                                   },
                                   "tip": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               },
                               "ios": {
                                 "type": "object",
                                 "properties": {
                                   "href": {
                                     "type": "string"
                                   },
                                   "tip": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               },
                               "android": {
                                 "type": "object",
                                 "properties": {
                                   "href": {
                                     "type": "string"
                                   },
                                   "tip": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           },
                           "task_id": {
                             "type": "string"
                           },
                           "created_at": {
                             "type": "string"
                           },
                           "updated_at": {
                             "type": "string"
                           },
                           "status": {
                             "type": "string"
                           },
                           "url": {
                             "type": "string"
                           },
                           "start": {
                             "type": "object",
                             "properties": {
                               "timestamp": {
                                 "type": "string"
                               },
                               "is_all_day": {
                                 "type": "boolean"
                               }
                             }
                           },
                           "subtask_count": {
                             "type": "integer"
                           },
                           "is_milestone": {
                             "type": "boolean"
                           },
                           "custom_fields": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "guid": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 },
                                 "number_value": {
                                   "type": "string"
                                 },
                                 "datetime_value": {
                                   "type": "string"
                                 },
                                 "member_value": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 },
                                 "single_select_value": {
                                   "type": "string"
                                 },
                                 "multi_select_value": {
                                   "type": "array",
                                   "items": {
                                     "type": "string"
                                   }
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "text_value": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "dependencies": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "type": {
                                   "type": "string"
                                 },
                                 "task_guid": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "assignee_related": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "completed_at": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "positive_reminders": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "relative_fire_minute": {
                                   "type": "integer"
                                 }
                               }
                             }
                           },
                           "agent_task_status": {
                             "type": "integer"
                           },
                           "agent_task_progress": {
                             "type": "string"
                           },
                           "text_deliveries": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "attachment_deliveries": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "guid": {
                                   "type": "string"
                                 },
                                 "file_token": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "size": {
                                   "type": "integer"
                                 },
                                 "resource": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "uploader": {
                                   "type": "object",
                                   "properties": {}
                                 },
                                 "is_cover": {
                                   "type": "boolean"
                                 },
                                 "uploaded_at": {
                                   "type": "string"
                                 },
                                 "url": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "next_task_guid": {
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
                   "path": "/open-apis/task/v2/tasks/:task_guid/subtasks",
                   "query": [
                     "page_size",
                     "page_token",
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:task:read"
                 ]
               },
               {
                 "name": "tasks_create_comment",
                 "description": "Tasks create comment.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "content": {
                       "type": "string"
                     },
                     "reply_to_comment_id": {
                       "type": "string"
                     },
                     "resource_type": {
                       "type": "string"
                     },
                     "resource_id": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "content",
                     "resource_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "comment": {
                       "type": "object",
                       "properties": {
                         "id": {
                           "type": "string"
                         },
                         "content": {
                           "type": "string"
                         },
                         "creator": {
                           "type": "object",
                           "properties": {
                             "id": {
                               "type": "string"
                             },
                             "type": {
                               "type": "string"
                             },
                             "role": {
                               "type": "string"
                             },
                             "name": {
                               "type": "string"
                             }
                           }
                         },
                         "reply_to_comment_id": {
                           "type": "string"
                         },
                         "created_at": {
                           "type": "string"
                         },
                         "updated_at": {
                           "type": "string"
                         },
                         "resource_type": {
                           "type": "string"
                         },
                         "resource_id": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/task/v2/comments",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:comment:write"
                 ]
               },
               {
                 "name": "tasks_list_comments",
                 "description": "Tasks list comments.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "resource_type": {
                       "type": "string"
                     },
                     "resource_id": {
                       "type": "string"
                     },
                     "direction": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
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
                           "id": {
                             "type": "string"
                           },
                           "content": {
                             "type": "string"
                           },
                           "creator": {
                             "type": "object",
                             "properties": {
                               "id": {
                                 "type": "string"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "role": {
                                 "type": "string"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           },
                           "reply_to_comment_id": {
                             "type": "string"
                           },
                           "created_at": {
                             "type": "string"
                           },
                           "updated_at": {
                             "type": "string"
                           },
                           "resource_type": {
                             "type": "string"
                           },
                           "resource_id": {
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
                   "path": "/open-apis/task/v2/comments",
                   "query": [
                     "page_size",
                     "page_token",
                     "resource_type",
                     "resource_id",
                     "direction",
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "task:comment:read"
                 ]
               }
             ]
             """)
  @tools Enum.map(@contracts, fn contract ->
           %ToolSpec{
             toolkit: "lark_tasks",
             name: contract["name"],
             description: contract["description"],
             input_schema: contract["input_schema"],
             output_schema: contract["output_schema"],
             operation: contract["operation"],
             subject_policy: :any_principal,
             upstream_auth: :adaptive_token,
             scopes: contract["scopes"],
             annotations:
               ToolSpec.annotations(
                 contract["read_only"],
                 contract["idempotent"],
                 contract["destructive"]
               )
           }
           |> ToolSpec.compile()
         end)

  def tools, do: @tools
end
