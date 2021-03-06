module EventMachine

  # EventMachine::Queue support
  # 
  #   queue = EM::Queue.new
  #   queue.push "glasses", "apples"
  #   result = []
  #   EM::Iterator.new(queue).each do |item, iter|
  #     result << "I have got #{item}"
  #     iter.next
  #   end
  #   queue.push "cars", "elephants"
  #   p result
  #   #=> ["I have got glasses", "I have got apples", "I have got cars", "I have got elephants"]
  #
  class QueueIsEmpty < RuntimeError; end
  module IteratorWithQueue
    def next_from_queue?
      raise(QueueIsEmpty) if @queue.empty?
      @queue.pop{ |q| @next_item = q}
      true
    end
  end

  # Support for Enumerable in Ruby 1.9+
  module IteratorWithEnumerable

    # In case of Enumerable object we can use lazyness of Enumerator
    def setup_list(list)
      raise ArgumentError, 'argument must be an Enumerable' unless list.respond_to?(:each)
      list.to_enum
    end

    # We can't check just next_item as far as it can return nil in two cases: 
    # when our enumerator is stopped and when it stores nil value
    def next?
      begin
        @next_item = @list.next
        true
      rescue StopIteration
        false
      rescue => e
        raise e
      end
    end
  end

  # Ruby 1.8 uses continuations in Enumerable, so we should use Arrays
  module IteratorWithArray

    def setup_list(list)
      raise ArgumentError, 'argument must be an array' unless list.respond_to?(:to_a)
      list.dup.to_a
    end

    def next?
      any = @list.any?
      @next_item = @list.shift
      any
    end
  end

  # A simple iterator for concurrent asynchronous work.
  #
  # Unlike ruby's built-in iterators, the end of the current iteration cycle is signaled manually,
  # instead of happening automatically after the yielded block finishes executing. For example:
  #
  #   (0..10).each{ |num| }
  #
  # becomes:
  #
  #   EM::Iterator.new(0..10).each{ |num,iter| iter.next }
  #
  # This is especially useful when doing asynchronous work via reactor libraries and
  # functions. For example, given a sync and async http api:
  #
  #   response = sync_http_get(url); ...
  #   async_http_get(url){ |response| ... }
  #
  # a synchronous iterator such as:
  #
  #   responses = urls.map{ |url| sync_http_get(url) }
  #   ...
  #   puts 'all done!'
  #
  # could be written as:
  #
  #   EM::Iterator.new(urls).map(proc{ |url,iter|
  #     async_http_get(url){ |res|
  #       iter.return(res)
  #     }
  #   }, proc{ |responses|
  #     ...
  #     puts 'all done!'
  #   })
  #
  # Now, you can take advantage of the asynchronous api to issue requests in parallel. For example,
  # to fetch 10 urls at a time, simply pass in a concurrency of 10:
  #
  #   EM::Iterator.new(urls, 10).each do |url,iter|
  #     async_http_get(url){ iter.next }
  #   end
  #

  class Iterator
    attr_reader :next_item

    include IteratorWithEnumerable if defined? Fiber
    include IteratorWithArray unless defined? Fiber
    include IteratorWithQueue

    # Create a new parallel async iterator with specified concurrency.
    #
    #   i = EM::Iterator.new(1..100, 10)
    #
    # will create an iterator over the range that processes 10 items at a time. Iteration
    # is started via #each, #map or #inject
    #
    def initialize(list, concurrency = 1)
      if list.class == EventMachine::Queue
        @queue = list
        alias :next? :next_from_queue?
      else
        @list = setup_list(list)
      end
      @concurrency = concurrency

      @started = false
      @ended = false
    end

    # Change the concurrency of this iterator. Workers will automatically be spawned or destroyed
    # to accomodate the new concurrency level.
    #
    def concurrency=(val)
      old = @concurrency
      @concurrency = val

      spawn_workers if val > old and @started and !@ended
    end
    attr_reader :concurrency

    # Iterate over a set of items using the specified block or proc.
    #
    #   EM::Iterator.new(1..100).each do |num, iter|
    #     puts num
    #     iter.next
    #   end
    #
    # An optional second proc is invoked after the iteration is complete.
    #
    #   EM::Iterator.new(1..100).each(
    #     proc{ |num,iter| iter.next },
    #     proc{ puts 'all done' }
    #   )
    #
    def each(foreach=nil, after=nil, &blk)
      raise ArgumentError, 'proc or block required for iteration' unless foreach ||= blk
      raise RuntimeError, 'cannot iterate over an iterator more than once' if @started or @ended

      @started = true
      @pending = 0
      @workers = 0

      all_done = proc{
        after.call if after and @ended and @pending == 0
      }

      @process_next = proc{
        # p [:process_next, :pending=, @pending, :workers=, @workers, :ended=, @ended, :concurrency=, @concurrency, :list=, @list]
        unless @ended or @workers > @concurrency
          begin
            if next?
              item = next_item
              @pending += 1

              is_done = false
              on_done = proc{
                raise RuntimeError, 'already completed this iteration' if is_done
                is_done = true

                @pending -= 1

                if @ended
                  all_done.call
                else
                  EM.next_tick(@process_next)
                end
              }
              class << on_done
                alias :next :call
              end

              foreach.call(item, on_done)
            else
              @ended = true
              @workers -= 1
              all_done.call
            end
          rescue EventMachine::QueueIsEmpty => e
            EM.next_tick(@process_next)
          end
        else
          @workers -= 1
        end
      }

      spawn_workers

      self
    end

    # Collect the results of an asynchronous iteration into an array.
    #
    #   EM::Iterator.new(%w[ pwd uptime uname date ], 2).map(proc{ |cmd,iter|
    #     EM.system(cmd){ |output,status|
    #       iter.return(output)
    #     }
    #   }, proc{ |results|
    #     p results
    #   })
    #
    def map(foreach, after)
      index = 0

      inject([], proc{ |results,item,iter|
        i = index
        index += 1

        is_done = false
        on_done = proc{ |res|
          raise RuntimeError, 'already returned a value for this iteration' if is_done
          is_done = true

          results[i] = res
          iter.return(results)
        }
        class << on_done
          alias :return :call
          def next
            raise NoMethodError, 'must call #return on a map iterator'
          end
        end

        foreach.call(item, on_done)
      }, proc{ |results|
        after.call(results)
      })
    end

    # Inject the results of an asynchronous iteration onto a given object.
    #
    #   EM::Iterator.new(%w[ pwd uptime uname date ], 2).inject({}, proc{ |hash,cmd,iter|
    #     EM.system(cmd){ |output,status|
    #       hash[cmd] = status.exitstatus == 0 ? output.strip : nil
    #       iter.return(hash)
    #     }
    #   }, proc{ |results|
    #     p results
    #   })
    #
    def inject(obj, foreach, after)
      each(proc{ |item,iter|
        is_done = false
        on_done = proc{ |res|
          raise RuntimeError, 'already returned a value for this iteration' if is_done
          is_done = true

          obj = res
          iter.next
        }
        class << on_done
          alias :return :call
          def next
            raise NoMethodError, 'must call #return on an inject iterator'
          end
        end

        foreach.call(obj, item, on_done)
      }, proc{
        after.call(obj)
      })
    end

    private

    # Spawn workers to consume items from the iterator's enumerator based on the current concurrency level.
    #
    def spawn_workers
      EM.next_tick(start_worker = proc{
        if @workers < @concurrency and !@ended
          # p [:spawning_worker, :workers=, @workers, :concurrency=, @concurrency, :ended=, @ended]
          @workers += 1
          @process_next.call
          EM.next_tick(start_worker)
        end
      })
      nil
    end
  end
end

if __FILE__ == $0
  $:.unshift File.join(File.dirname(__FILE__), '..')
  require 'eventmachine'

  # TODO: real tests
  # TODO: pass in one object instead of two? .each{ |iter| puts iter.current; iter.next }
  # TODO: support iter.pause/resume/stop/break/continue?
  # TODO: create some exceptions instead of using RuntimeError
  # TODO: support proc instead of enumerable? EM::Iterator.new(proc{ return queue.pop })

  EM.run{
    EM::Iterator.new(1..50).each{ |num,iter| p num; iter.next }
    EM::Iterator.new([1,2,3], 10).each{ |num,iter| p num; iter.next }

    i = EM::Iterator.new(1..100, 5)
    i.each(proc{|num,iter|
      p num.to_s
      iter.next
    }, proc{
      p :done
    })
    EM.add_timer(0.03){
      i.concurrency = 1
    }
    EM.add_timer(0.04){
      i.concurrency = 3
    }

    EM::Iterator.new(100..150).map(proc{ |num,iter|
      EM.add_timer(0.01){ iter.return(num) }
    }, proc{ |results|
      p results
    })

    EM::Iterator.new(%w[ pwd uptime uname date ], 2).inject({}, proc{ |hash,cmd,iter|
      EM.system(cmd){ |output,status|
        hash[cmd] = status.exitstatus == 0 ? output.strip : nil
        iter.return(hash)
      }
    }, proc{ |results|
      p results
    })
  }
end